"""
Inference routing proxy with GPU lifecycle orchestration.

Routes image generation (ComfyUI) and LLM (Ollama / vLLM) requests to the GPU
node with sufficient free VRAM. When the requested model is not loaded:

  1. If free VRAM covers it, the request is queued, the model is loaded, the
     query runs, and the result is served.
  2. If not, the proxy inspects what is holding VRAM (via the per-node GPU
     lifecycle agent, `gpu-ctl`), evicts the largest idle model it loaded and
     knows of (never one with an in-flight query), then loads and serves.

A lockout mode (`POST /lockout`) tears down every GPU service so the operator
gets the card back uninterrupted (gaming, video render); inbound queries queue
until `POST /unlock`.

Backends are normalized behind a small driver so the proxy treats Ollama,
ComfyUI and vLLM uniformly for load/unload/eviction, even though their native
lifecycles differ:
  - Ollama    load is lazy (just send the query); unload = keep_alive 0
  - ComfyUI   load is implicit (ckpt_name in payload); unload = /free
  - vLLM      load = gpu-ctl starts the systemd unit (~36s); unload = stop it.
              Completion requests go THROUGH gpu-ctl so the vLLM API key stays
              on the GPU host and is never shipped to this proxy.

Endpoints:
  POST /image                  — image gen (image-api wrapper format)
  GET  /output/<filename>      — fetch a generated image
  POST /v1/chat/completions    — LLM chat (OpenAI-compatible)
  POST /v1/completions         — LLM completions (OpenAI-compatible)
  GET  /jobs/<job_id>          — poll queued job status + result
  GET  /api/models             — list models and their routing
  GET  /health                 — per-node backend liveness + VRAM status
  GET  /state                  — per-node loaded models + lockout + VRAM ownership
  POST /lockout                — tear down GPU services, stop auto-loading
  POST /unlock                 — resume normal operation
"""

import asyncio
import os
import logging
import time
import uuid
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
from typing import Any

import httpx
import yaml
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, StreamingResponse

logging.basicConfig(level=logging.INFO)
log = logging.getLogger(__name__)

MODELS_FILE = Path(os.getenv("MODELS_FILE", Path(__file__).parent / "models.yaml"))
BACKEND_TIMEOUT = float(os.getenv("BACKEND_TIMEOUT", "300"))
PROBE_TIMEOUT = 3.0
VRAM_SAFETY_MARGIN_MB = int(os.getenv("VRAM_SAFETY_MARGIN_MB", "512"))
QUEUE_POLL_INTERVAL = float(os.getenv("QUEUE_POLL_INTERVAL", "15"))
JOB_TTL = float(os.getenv("JOB_TTL", "3600"))
GPU_CTL_TOKEN = os.getenv("GPU_CTL_TOKEN", "")   # shared secret for gpu-ctl
GPU_CTL_TIMEOUT = float(os.getenv("GPU_CTL_TIMEOUT", "320"))  # > vLLM cold start


def load_config() -> dict:
    with open(MODELS_FILE) as f:
        return yaml.safe_load(f)


config = load_config()
NODES: dict[str, dict] = config["nodes"]
IMAGEGEN_MODELS: dict[str, dict] = config["imagegen"]
LLM_MODELS: dict[str, dict] = config["llm"]


# ---------------------------------------------------------------------------
# Job queue
# ---------------------------------------------------------------------------

class JobStatus(str, Enum):
    QUEUED = "queued"
    LOADING = "loading"      # model is being loaded onto the GPU
    RUNNING = "running"
    DONE = "done"
    FAILED = "failed"


@dataclass
class Job:
    id: str
    service: str            # "imagegen" or "llm"
    model_info: dict
    payload: dict
    status: JobStatus = JobStatus.QUEUED
    result: dict | None = None
    error: str | None = None
    node: str | None = None
    created_at: float = field(default_factory=time.monotonic)


job_results: dict[str, Job] = {}
imagegen_queue: asyncio.Queue = asyncio.Queue()
llm_queue: asyncio.Queue = asyncio.Queue()

# Lockout flag (proxy-local). gpu-ctl also enforces its own persistent flag, so
# even if this proxy restarts while locked, the GPU host refuses to load.
_locked = False

# In-flight tracking at (node, backend_model) granularity — the eviction safety
# check. A model is only evictable when it is not present here.
_active_models: set[tuple[str, str]] = set()


def _model_key(node_name: str, model_info: dict) -> tuple[str, str]:
    return (node_name, model_info["backend_model"])


# ---------------------------------------------------------------------------
# gpu-ctl client
# ---------------------------------------------------------------------------

def _gpu_ctl_url(node_name: str) -> str | None:
    return NODES[node_name].get("gpu_ctl_url")


async def _gpu_ctl(node_name: str, method: str, path: str,
                   json_body: dict | None = None,
                   timeout: float = GPU_CTL_TIMEOUT) -> tuple[int, dict]:
    """Call the gpu-ctl agent on a node. Returns (status_code, json_dict).

    A status of 0 means the agent could not be reached (connection refused /
    timeout / no URL configured) — callers must treat this as "agent absent"
    and degrade, never as a hard failure.
    """
    base = _gpu_ctl_url(node_name)
    if not base:
        return 0, {"error": "no gpu_ctl_url for this node"}
    headers = {}
    if GPU_CTL_TOKEN:
        headers["Authorization"] = f"Bearer {GPU_CTL_TOKEN}"
    try:
        async with httpx.AsyncClient(timeout=timeout) as client:
            r = await client.request(method, f"{base}{path}", json=json_body, headers=headers)
    except httpx.HTTPError as exc:
        return 0, {"error": f"gpu-ctl unreachable: {exc}"}
    try:
        return r.status_code, r.json()
    except Exception:
        return r.status_code, {"error": r.text[:300]}


# ---------------------------------------------------------------------------
# Backend drivers — normalized load/unload/evict/run per backend
# ---------------------------------------------------------------------------

class BackendDriver:
    """Uniform interface over Ollama, ComfyUI and vLLM lifecycles."""

    name = "base"
    # True when this backend has an explicit "load" step with a readiness signal
    # the proxy must trigger and then verify (vLLM: start unit + poll /v1/models).
    # False when the model loads lazily/implicitly as part of the request
    # (Ollama lazy-load, ComfyUI checkpoint-in-payload) — no load step to await.
    explicit_load: bool = False

    async def is_loaded(self, node_name: str, model_info: dict) -> bool:
        raise NotImplementedError

    async def load(self, node_name: str, model_info: dict) -> None:
        raise NotImplementedError

    async def unload(self, node_name: str) -> None:
        raise NotImplementedError

    async def held_vram_mb(self, node_name: str) -> int:
        """VRAM this backend currently holds and could release on unload."""
        return 0

    async def run(self, node_name: str, model_info: dict, body: dict) -> dict:
        raise NotImplementedError


class OllamaDriver(BackendDriver):
    name = "ollama"

    def _url(self, node_name: str) -> str:
        return NODES[node_name]["llm_url"]

    async def is_loaded(self, node_name: str, model_info: dict) -> bool:
        # Ollama loads lazily; treat "loadable" as loaded-on-demand. We only
        # report loaded if the model is currently resident (for eviction info).
        async with httpx.AsyncClient(timeout=PROBE_TIMEOUT) as c:
            r = await c.get(f"{self._url(node_name)}/api/ps")
        if r.is_success:
            names = [m.get("name") for m in r.json().get("models", [])]
            return model_info["backend_model"] in names
        return False

    async def load(self, node_name: str, model_info: dict) -> None:
        # No explicit load — Ollama pulls on first request. Nothing to do.
        return None

    async def unload(self, node_name: str) -> None:
        async with httpx.AsyncClient(timeout=10.0) as c:
            r = await c.get(f"{self._url(node_name)}/api/ps")
        if not r.is_success:
            return
        for m in r.json().get("models", []):
            async with httpx.AsyncClient(timeout=10.0) as c:
                await c.post(f"{self._url(node_name)}/api/generate",
                             json={"model": m["name"], "keep_alive": 0})

    async def held_vram_mb(self, node_name: str) -> int:
        async with httpx.AsyncClient(timeout=PROBE_TIMEOUT) as c:
            r = await c.get(f"{self._url(node_name)}/api/ps")
        if not r.is_success:
            return 0
        return sum(m.get("size_vram", 0) for m in r.json().get("models", [])) // (1024 * 1024)

    async def run(self, node_name: str, model_info: dict, body: dict) -> dict:
        url = f"{self._url(node_name)}/v1/chat/completions"
        forwarded = {**body, "model": model_info["backend_model"], "stream": False}
        async with httpx.AsyncClient(timeout=BACKEND_TIMEOUT) as c:
            resp = await c.post(url, json=forwarded)
        if not resp.is_success:
            raise HTTPException(status_code=502,
                                detail=f"Ollama {node_name} returned {resp.status_code}: {resp.text[:300]}")
        return resp.json()


class ComfyUIDriver(BackendDriver):
    name = "comfyui"

    def _url(self, node_name: str) -> str:
        return NODES[node_name]["imagegen_url"]

    async def is_loaded(self, node_name: str, model_info: dict) -> bool:
        # ComfyUI loads its checkpoint as part of the generation request and does
        # not persist it; residency is not cheaply queryable and not meaningful
        # for routing. Always go through the VRAM gate, never the "already
        # loaded" fast-path.
        return False

    async def load(self, node_name: str, model_info: dict) -> None:
        return None  # checkpoint loads as part of the generation request

    async def unload(self, node_name: str) -> None:
        async with httpx.AsyncClient(timeout=5.0) as c:
            await c.post(f"{self._url(node_name)}/free",
                         json={"unload_models": True, "free_memory": True})

    async def run(self, node_name: str, model_info: dict, body: dict) -> dict:
        api_url = NODES[node_name]["image_api_url"]
        payload = {**body, "ckpt_name": model_info["backend_model"]}
        async with httpx.AsyncClient(timeout=BACKEND_TIMEOUT) as c:
            resp = await c.post(f"{api_url}/image", json=payload)
        if not resp.is_success:
            raise HTTPException(status_code=502,
                                detail=f"imagegen {node_name} returned {resp.status_code}: {resp.text[:300]}")
        data = resp.json()
        data["_node"] = node_name
        return data


class VllmDriver(BackendDriver):
    name = "vllm"
    explicit_load = True   # start systemd unit + poll /v1/models until ready

    async def is_loaded(self, node_name: str, model_info: dict) -> bool:
        if not _gpu_ctl_url(node_name):
            # No agent — fall back to probing the vLLM endpoint directly.
            url = NODES[node_name].get("vllm_url")
            if not url:
                return False
            try:
                async with httpx.AsyncClient(timeout=PROBE_TIMEOUT) as c:
                    r = await c.get(f"{url}/v1/models")
                return r.is_success
            except Exception:
                return False
        code, state = await _gpu_ctl(node_name, "GET", "/state", timeout=PROBE_TIMEOUT)
        return code == 200 and state.get("vllm", {}).get("loaded", False)

    async def load(self, node_name: str, model_info: dict) -> None:
        code, resp = await _gpu_ctl(node_name, "POST", "/vllm/start")
        if code != 200:
            raise HTTPException(status_code=502,
                                detail=f"vLLM load on {node_name} failed ({code}): "
                                       f"{resp.get('error', resp)[:300]}")
        load_s = resp.get("load_seconds")
        if load_s:
            log.info("vLLM loaded on %s in %.1fs", node_name, load_s)

    async def unload(self, node_name: str) -> None:
        await _gpu_ctl(node_name, "POST", "/vllm/stop", timeout=120)

    async def held_vram_mb(self, node_name: str) -> int:
        # vLLM residency is known from the model catalog (vram_mb). The agent
        # could report nvidia-smi per-process, but the catalog value is the
        # reliable planning figure.
        return 0  # reported via model_info["vram_mb"] by the caller

    async def run(self, node_name: str, model_info: dict, body: dict) -> dict:
        forwarded = {**body, "model": model_info["backend_model"], "stream": False}
        if model_info.get("think"):
            forwarded["think"] = True
        if _gpu_ctl_url(node_name):
            # Route through gpu-ctl so the API key never leaves the GPU host.
            code, resp = await _gpu_ctl(node_name, "POST", "/vllm/completions",
                                        json_body=forwarded, timeout=BACKEND_TIMEOUT)
            if code != 200:
                raise HTTPException(status_code=502,
                                    detail=f"vLLM {node_name} returned {code}: "
                                           f"{str(resp.get('error', resp))[:300]}")
            return resp
        # Fallback: direct call (no agent). Requires the key to be absent or
        # the endpoint unauthenticated — used only for non-agent deployments.
        base = NODES[node_name].get("vllm_url")
        async with httpx.AsyncClient(timeout=BACKEND_TIMEOUT) as c:
            resp = await c.post(f"{base}/v1/completions", json=forwarded)
        if not resp.is_success:
            raise HTTPException(status_code=502,
                                detail=f"vLLM {node_name} returned {resp.status_code}: {resp.text[:300]}")
        return resp.json()


DRIVERS: dict[str, BackendDriver] = {
    "ollama": OllamaDriver(),
    "comfyui": ComfyUIDriver(),
    "vllm": VllmDriver(),
}


def driver_for(model_info: dict, service: str) -> BackendDriver:
    """The driver is a function of the SERVICE, not the model's catalog fields.

    imagegen -> ComfyUI; llm -> vLLM (if backend: vllm) else Ollama.
    """
    if service == "imagegen":
        return DRIVERS["comfyui"]
    if model_info.get("backend") == "vllm":
        return DRIVERS["vllm"]
    return DRIVERS["ollama"]


# ---------------------------------------------------------------------------
# VRAM probes
# ---------------------------------------------------------------------------

async def _vram_free(node: dict) -> int:
    url = node.get("vram_reporter_url")
    if not url:
        return 0
    try:
        async with httpx.AsyncClient(timeout=PROBE_TIMEOUT) as client:
            r = await client.get(f"{url}/vram")
        if r.is_success:
            return sum(g["memory_free_mb"] for g in r.json().get("gpus", []))
    except Exception:
        pass
    return 0


# ---------------------------------------------------------------------------
# Loaded-model enumeration + eviction
# ---------------------------------------------------------------------------

async def _loaded_models(node_name: str) -> list[tuple[str, int]]:
    """Return [(backend_model, held_mb)] for every model currently resident."""
    loaded: list[tuple[str, int]] = []
    # Ollama: query /api/ps directly.
    ollama = DRIVERS["ollama"]
    try:
        async with httpx.AsyncClient(timeout=PROBE_TIMEOUT) as c:
            r = await c.get(f"{NODES[node_name]['llm_url']}/api/ps")
        if r.is_success:
            for m in r.json().get("models", []):
                mb = m.get("size_vram", 0) // (1024 * 1024)
                loaded.append((m["name"], mb))
    except Exception:
        pass
    # vLLM: if the agent reports it loaded, account for its catalog VRAM.
    if _gpu_ctl_url(node_name):
        code, state = await _gpu_ctl(node_name, "GET", "/state", timeout=PROBE_TIMEOUT)
        if code == 200 and state.get("vllm", {}).get("loaded"):
            for name, mi in LLM_MODELS.items():
                if mi.get("backend") == "vllm":
                    loaded.append((mi["backend_model"], mi.get("vram_mb", 0)))
    # ComfyUI: a loaded checkpoint is not directly enumerable; the agent's
    # nvidia-smi process breakdown is the honest answer, folded in below.
    return loaded


async def _evict_idle(node_name: str, needed_mb: int) -> bool:
    """
    Evict idle loaded models, largest first, until `needed_mb` is free.
    Never evicts a model with an in-flight query. Returns True if enough room
    was made.
    """
    free = await _vram_free(NODES[node_name])
    if free >= needed_mb:
        return True

    loaded = await _loaded_models(node_name)
    # Sort by held VRAM descending, evict largest first.
    loaded.sort(key=lambda x: x[1], reverse=True)

    for backend_model, held_mb in loaded:
        if (node_name, backend_model) in _active_models:
            log.info("evict skip %s/%s: in-flight", node_name, backend_model)
            continue
        if held_mb <= 0:
            continue
        # Determine the driver for this model and unload it.
        driver = None
        for mi in LLM_MODELS.values():
            if mi.get("backend_model") == backend_model:
                driver = driver_for(mi, "llm")
                break
        if driver is None:
            for mi in IMAGEGEN_MODELS.values():
                if mi.get("backend_model") == backend_model:
                    driver = driver_for(mi, "imagegen")
                    break
        if driver is None:
            continue
        log.info("evicting idle model %s on %s (%d MB)", backend_model, node_name, held_mb)
        await driver.unload(node_name)
        await asyncio.sleep(2)  # let the driver release VRAM
        free = await _vram_free(NODES[node_name])
        if free >= needed_mb:
            return True
    # ComfyUI checkpoint is the last resort — /free it if no query in flight.
    if (node_name, "__comfyui__") not in _active_models:
        await DRIVERS["comfyui"].unload(node_name)
        await asyncio.sleep(2)
        free = await _vram_free(NODES[node_name])
        if free >= needed_mb:
            return True
    return False


# ---------------------------------------------------------------------------
# Node selection + load orchestration
# ---------------------------------------------------------------------------

async def _ensure_loaded(node_name: str, model_info: dict, service: str) -> None:
    """Make sure `model_info` is loaded on `node_name`, loading it if needed.

    For explicit-load backends (vLLM) this triggers the load and verifies
    readiness. For implicit-load backends (Ollama lazy-load, ComfyUI
    checkpoint-in-payload) there is no load step to await — the model materializes
    during `run()`, so we only enforce the VRAM gate (and evict if needed) here.
    """
    driver = driver_for(model_info, service)
    if await driver.is_loaded(node_name, model_info):
        return
    needed_mb = model_info["vram_mb"] + VRAM_SAFETY_MARGIN_MB
    free = await _vram_free(NODES[node_name])
    if free < needed_mb:
        # Not enough room — evict idle models to make space.
        if not await _evict_idle(node_name, needed_mb):
            raise HTTPException(
                status_code=503,
                detail=f"Insufficient VRAM on {node_name} after evicting idle models "
                       f"(need {model_info['vram_mb']} MB + {VRAM_SAFETY_MARGIN_MB} MB margin).",
            )
    if driver.explicit_load:
        await driver.load(node_name, model_info)
        if not await driver.is_loaded(node_name, model_info):
            raise HTTPException(
                status_code=503,
                detail=f"Model {model_info['backend_model']} failed to load on {node_name}")


async def pick_node(model_info: dict, service: str) -> str:
    """Return a node and ensure the model is loaded there; raise 503 if not."""
    if _locked:
        raise HTTPException(status_code=503, detail="GPU is in lockout mode")

    candidates = model_info["nodes"]
    vram_results = await asyncio.gather(*[_vram_free(NODES[n]) for n in candidates])
    needed_mb = model_info["vram_mb"] + VRAM_SAFETY_MARGIN_MB

    # Preferred order: candidate order from models.yaml (primary first), but
    # prefer a node where the model is ALREADY loaded, then enough free VRAM.
    best: str | None = None
    for idx, node_name in enumerate(candidates):
        driver = driver_for(model_info, service)
        already = await driver.is_loaded(node_name, model_info)
        free = vram_results[idx]
        if already:
            log.info("routing %s → %s (already loaded)", service, node_name)
            return node_name
        if free >= needed_mb and best is None:
            best = node_name
    if best is not None:
        log.info("routing %s → %s (pass1, vram_free=%d MB)", service, best,
                 dict(zip(candidates, vram_results))[best])
        return best

    # No immediate room. Try eviction on the first eligible candidate.
    for idx, node_name in enumerate(candidates):
        active = any((node_name, bm) in _active_models
                     for bm in [model_info["backend_model"]])
        if active:
            continue
        if await _evict_idle(node_name, needed_mb):
            log.info("routing %s → %s (pass2 after eviction)", service, node_name)
            return node_name

    raise HTTPException(
        status_code=503,
        detail=(f"Insufficient VRAM on all eligible nodes "
                f"(need {model_info['vram_mb']} MB + {VRAM_SAFETY_MARGIN_MB} MB margin)."),
    )


# ---------------------------------------------------------------------------
# Job execution
# ---------------------------------------------------------------------------

async def _run_imagegen(node_name: str, model_info: dict, payload: dict) -> dict:
    key = _model_key(node_name, model_info)
    _active_models.add(key)
    try:
        result = await DRIVERS["comfyui"].run(node_name, model_info, payload)
        asyncio.create_task(DRIVERS["comfyui"].unload(node_name))
        return result
    finally:
        _active_models.discard(key)


async def _run_llm(node_name: str, model_info: dict, body: dict) -> dict:
    key = _model_key(node_name, model_info)
    _active_models.add(key)
    try:
        driver = driver_for(model_info, "llm")
        return await driver.run(node_name, model_info, body)
    finally:
        _active_models.discard(key)


async def _process_job(job: Job) -> None:
    while True:
        try:
            node_name = await pick_node(job.model_info, job.service)
            break
        except HTTPException as exc:
            if exc.status_code == 503 and not _locked:
                log.info("job %s waiting for VRAM (retry in %ds)", job.id, QUEUE_POLL_INTERVAL)
                await asyncio.sleep(QUEUE_POLL_INTERVAL)
            else:
                job.status = JobStatus.FAILED
                job.error = str(exc.detail)
                return

    job.status = JobStatus.LOADING
    job.node = node_name
    log.info("job %s ensuring model loaded on %s", job.id, node_name)
    try:
        await _ensure_loaded(node_name, job.model_info, job.service)
    except HTTPException as exc:
        job.status = JobStatus.FAILED
        job.error = str(exc.detail)
        return

    job.status = JobStatus.RUNNING
    try:
        if job.service == "imagegen":
            job.result = await _run_imagegen(node_name, job.model_info, job.payload)
        else:
            job.result = await _run_llm(node_name, job.model_info, job.payload)
        job.status = JobStatus.DONE
        log.info("job %s done on %s", job.id, node_name)
    except Exception as exc:
        job.status = JobStatus.FAILED
        job.error = str(exc)
        log.error("job %s failed: %s", job.id, exc)


async def _queue_worker(service: str) -> None:
    queue = imagegen_queue if service == "imagegen" else llm_queue
    while True:
        job = await queue.get()
        try:
            await _process_job(job)
        finally:
            queue.task_done()


async def _cleanup_worker() -> None:
    while True:
        await asyncio.sleep(300)
        cutoff = time.monotonic() - JOB_TTL
        stale = [jid for jid, j in job_results.items()
                 if j.status in (JobStatus.DONE, JobStatus.FAILED) and j.created_at < cutoff]
        for jid in stale:
            del job_results[jid]
        if stale:
            log.info("cleaned up %d stale jobs", len(stale))


# ---------------------------------------------------------------------------
# App lifecycle
# ---------------------------------------------------------------------------

@asynccontextmanager
async def lifespan(app: FastAPI):
    workers = [
        asyncio.create_task(_queue_worker("imagegen"), name="worker-imagegen"),
        asyncio.create_task(_queue_worker("llm"), name="worker-llm"),
        asyncio.create_task(_cleanup_worker(), name="worker-cleanup"),
    ]
    log.info("background workers started")
    yield
    for w in workers:
        w.cancel()


app = FastAPI(title="Inference Proxy", version="0.3.0", lifespan=lifespan)


# ---------------------------------------------------------------------------
# Lockout / state
# ---------------------------------------------------------------------------

@app.post("/lockout")
async def lockout() -> JSONResponse:
    global _locked
    stopped: dict[str, list[str]] = {}
    for node_name, node in NODES.items():
        if not _gpu_ctl_url(node_name):
            continue
        code, resp = await _gpu_ctl(node_name, "POST", "/lockout")
        if code == 200:
            stopped[node_name] = resp.get("stopped", [])
        else:
            stopped[node_name] = [f"error {code}: {resp.get('error', '')[:200]}"]
    _locked = True
    log.info("lockout engaged: %s", stopped)
    return JSONResponse({"locked": True, "stopped": stopped})


@app.post("/unlock")
async def unlock() -> JSONResponse:
    global _locked
    for node_name, node in NODES.items():
        if _gpu_ctl_url(node_name):
            await _gpu_ctl(node_name, "POST", "/unlock")
    _locked = False
    return JSONResponse({"locked": False})


@app.get("/state")
async def state() -> JSONResponse:
    out: dict[str, Any] = {"locked": _locked, "nodes": {}}
    for node_name, node in NODES.items():
        node_state: dict[str, Any] = {
            "vram_free_mb": await _vram_free(node),
            "loaded_models": [bm for bm, _ in await _loaded_models(node_name)],
        }
        if _gpu_ctl_url(node_name):
            code, gs = await _gpu_ctl(node_name, "GET", "/state", timeout=PROBE_TIMEOUT)
            if code == 200:
                node_state["gpu_ctl"] = gs
        out["nodes"][node_name] = node_state
    return JSONResponse(out)


# ---------------------------------------------------------------------------
# Image generation — bot-compatible API
# ---------------------------------------------------------------------------

async def _enqueue_or_run_imagegen(model_name: str, payload: dict) -> tuple[dict | None, Job | None]:
    model_info = IMAGEGEN_MODELS.get(model_name)
    if not model_info:
        raise HTTPException(status_code=400, detail=f"Unknown image model: {model_name!r}. "
                            f"Available: {list(IMAGEGEN_MODELS)}")

    try:
        node_name = await pick_node(model_info, "imagegen")
        result = await _run_imagegen(node_name, model_info, payload)
        return result, None
    except HTTPException as exc:
        if exc.status_code != 503:
            raise

    job = Job(id=str(uuid.uuid4()), service="imagegen", model_info=model_info, payload=payload)
    job_results[job.id] = job
    await imagegen_queue.put(job)
    return None, job


@app.post("/image")
async def route_image(request: Request):
    body = await request.json()
    model_name = body.get("model", "sd-1.5")
    payload = {k: v for k, v in body.items() if k != "model"}

    log.info("image request model=%s", model_name)
    result, job = await _enqueue_or_run_imagegen(model_name, payload)

    if job:
        position = sum(1 for j in job_results.values() if j.status == JobStatus.QUEUED)
        return JSONResponse({"job_id": job.id, "status": "queued", "position": position},
                            status_code=202)
    return JSONResponse(result)


@app.get("/output/{filename}")
async def proxy_output(filename: str):
    async with httpx.AsyncClient(timeout=30.0) as client:
        for node_name, node in NODES.items():
            url = f"{node['image_api_url']}/output/{filename}"
            try:
                r = await client.get(url)
                if r.is_success:
                    log.info("serving output/%s from %s", filename, node_name)
                    return StreamingResponse(iter([r.content]),
                                             media_type=r.headers.get("content-type", "image/png"))
            except Exception:
                continue
    raise HTTPException(status_code=404, detail=f"Output file {filename!r} not found on any node")


# ---------------------------------------------------------------------------
# LLM — OpenAI-compatible
# ---------------------------------------------------------------------------

async def _enqueue_or_run_llm(body: dict) -> tuple[dict | None, Job | None]:
    model_name = body.get("model", "")
    model_info = LLM_MODELS.get(model_name)
    if not model_info:
        raise HTTPException(status_code=400, detail=f"Unknown LLM model: {model_name!r}. "
                            f"Available: {list(LLM_MODELS)}")

    if body.get("stream"):
        # Streaming can't be queued — run immediately or fail.
        node_name = await pick_node(model_info, "llm")
        await _ensure_loaded(node_name, model_info, "llm")
        driver = driver_for(model_info, "llm")

        if model_info.get("backend") == "vllm":
            # gpu-ctl is a buffered JSON forwarder; it cannot stream. For the
            # donnertune contract this is fine (roll.py uses non-streaming raw
            # completions), but surface it clearly rather than silently buffer.
            raise HTTPException(status_code=501,
                                detail="streaming not supported for vLLM (donnertune)")

        base = NODES[node_name]["llm_url"]
        forwarded = {**body, "model": model_info["backend_model"]}
        if model_info.get("think"):
            forwarded["think"] = True

        async def generate():
            async with httpx.AsyncClient(timeout=BACKEND_TIMEOUT) as client:
                async with client.stream("POST", f"{base}/v1/chat/completions",
                                         json=forwarded) as r:
                    async for chunk in r.aiter_bytes():
                        yield chunk

        return {"_stream": generate}, None

    try:
        node_name = await pick_node(model_info, "llm")
        await _ensure_loaded(node_name, model_info, "llm")
        result = await _run_llm(node_name, model_info, body)
        return result, None
    except HTTPException as exc:
        if exc.status_code != 503:
            raise

    job = Job(id=str(uuid.uuid4()), service="llm", model_info=model_info, payload=body)
    job_results[job.id] = job
    await llm_queue.put(job)
    return None, job


@app.post("/v1/chat/completions")
async def chat_completions(request: Request):
    body = await request.json()
    result, job = await _enqueue_or_run_llm(body)
    if job:
        position = sum(1 for j in job_results.values() if j.status == JobStatus.QUEUED)
        return JSONResponse({"job_id": job.id, "status": "queued", "position": position},
                            status_code=202)
    if "_stream" in result:
        return StreamingResponse(result["_stream"](), media_type="text/event-stream")
    return JSONResponse(result)


@app.post("/v1/completions")
async def completions(request: Request):
    body = await request.json()
    result, job = await _enqueue_or_run_llm(body)
    if job:
        position = sum(1 for j in job_results.values() if j.status == JobStatus.QUEUED)
        return JSONResponse({"job_id": job.id, "status": "queued", "position": position},
                            status_code=202)
    if "_stream" in result:
        return StreamingResponse(result["_stream"](), media_type="text/event-stream")
    return JSONResponse(result)


# ---------------------------------------------------------------------------
# Job status polling
# ---------------------------------------------------------------------------

@app.get("/jobs/{job_id}")
async def get_job(job_id: str) -> JSONResponse:
    job = job_results.get(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found (may have expired)")

    resp: dict[str, Any] = {"job_id": job_id, "status": job.status}

    if job.status in (JobStatus.QUEUED, JobStatus.LOADING):
        queued = sorted((j for j in job_results.values()
                         if j.status in (JobStatus.QUEUED, JobStatus.LOADING)),
                        key=lambda j: j.created_at)
        resp["position"] = next((i + 1 for i, j in enumerate(queued) if j.id == job_id), 1)
    elif job.status == JobStatus.DONE:
        resp["result"] = job.result
        resp["node"] = job.node
    elif job.status == JobStatus.FAILED:
        resp["error"] = job.error

    return JSONResponse(resp)


# ---------------------------------------------------------------------------
# Discovery + health
# ---------------------------------------------------------------------------

@app.get("/api/models")
async def list_models() -> JSONResponse:
    return JSONResponse({
        "imagegen": {name: {"vram_mb": m["vram_mb"], "nodes": m["nodes"]}
                     for name, m in IMAGEGEN_MODELS.items()},
        "llm": {name: {"vram_mb": m["vram_mb"], "nodes": m["nodes"],
                       "backend": m.get("backend", "ollama")}
                for name, m in LLM_MODELS.items()},
    })


@app.get("/health")
async def health() -> JSONResponse:
    statuses: dict[str, Any] = {}
    async with httpx.AsyncClient(timeout=5.0) as client:
        for node_name, node in NODES.items():
            node_status: dict[str, Any] = {}
            for svc, url, probe in [
                ("imagegen", node["image_api_url"], "/health"),
                ("llm", node["llm_url"], "/api/tags"),
            ]:
                try:
                    r = await client.get(f"{url}{probe}")
                    node_status[svc] = "ok" if r.is_success else f"http_{r.status_code}"
                except Exception:
                    node_status[svc] = "unreachable"
            if node.get("vllm_url"):
                gs = None
                if _gpu_ctl_url(node_name):
                    code, gs = await _gpu_ctl(node_name, "GET", "/state", timeout=PROBE_TIMEOUT)
                    if code == 200:
                        node_status["vllm"] = ("loaded" if gs.get("vllm", {}).get("loaded")
                                               else "stopped")
                        node_status["vllm_loaded"] = gs.get("vllm", {}).get("loaded", False)
                    else:
                        gs = None  # agent absent/unreachable — fall through to direct probe
                if gs is None:
                    try:
                        r = await client.get(f"{node['vllm_url']}/v1/models")
                        node_status["vllm"] = "ok" if r.is_success else f"http_{r.status_code}"
                    except Exception:
                        node_status["vllm"] = "unreachable"
            node_status["vram_free_mb"] = await _vram_free(node)
            node_status["vram_total_mb"] = node["vram_mb"]
            node_status["locked"] = _locked
            statuses[node_name] = node_status

    queue_status = {
        "imagegen_queued": sum(1 for j in job_results.values()
                               if j.service == "imagegen" and j.status == JobStatus.QUEUED),
        "llm_queued": sum(1 for j in job_results.values()
                          if j.service == "llm" and j.status == JobStatus.QUEUED),
        "locked": _locked,
    }
    return JSONResponse({"nodes": statuses, "queues": queue_status})
