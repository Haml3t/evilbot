"""
Inference routing proxy.

Routes image generation (ComfyUI) and LLM (Ollama) requests to the GPU node
with sufficient free VRAM. Uses live nvidia-smi data from a VRAM reporter
service running on each node.

If no node has enough free VRAM, requests are queued and processed once
resources become available.

Endpoints:
  POST /image                  — image gen (image-api wrapper format)
  GET  /output/<filename>      — fetch a generated image from whichever node has it
  POST /v1/chat/completions    — LLM chat (OpenAI-compatible)
  POST /v1/completions         — LLM completions (OpenAI-compatible)
  GET  /jobs/<job_id>          — poll queued job status + result
  GET  /api/models             — list models and their routing
  GET  /health                 — per-node backend liveness + VRAM status
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
QUEUE_POLL_INTERVAL = float(os.getenv("QUEUE_POLL_INTERVAL", "15"))   # seconds between VRAM rechecks
JOB_TTL = float(os.getenv("JOB_TTL", "3600"))                         # seconds to keep completed jobs


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
    QUEUED  = "queued"
    RUNNING = "running"
    DONE    = "done"
    FAILED  = "failed"


@dataclass
class Job:
    id: str
    service: str          # "imagegen" or "llm"
    model_info: dict
    payload: dict         # cleaned request body forwarded to backend
    status: JobStatus = JobStatus.QUEUED
    result: dict | None = None
    error: str | None = None
    node: str | None = None
    created_at: float = field(default_factory=time.monotonic)


job_results: dict[str, Job] = {}
imagegen_queue: asyncio.Queue = asyncio.Queue()
llm_queue: asyncio.Queue = asyncio.Queue()


# ---------------------------------------------------------------------------
# VRAM + queue-depth probes
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


async def _comfyui_queue_depth(node: dict) -> int:
    try:
        async with httpx.AsyncClient(timeout=PROBE_TIMEOUT) as client:
            r = await client.get(f"{node['imagegen_url']}/queue")
        if r.is_success:
            data = r.json()
            return len(data.get("queue_running", [])) + len(data.get("queue_pending", []))
    except Exception:
        pass
    return 999


async def _ollama_active_count(node: dict) -> int:
    try:
        async with httpx.AsyncClient(timeout=PROBE_TIMEOUT) as client:
            r = await client.get(f"{node['llm_url']}/api/ps")
        if r.is_success:
            return len(r.json().get("models", []))
    except Exception:
        pass
    return 999


async def pick_node(model_info: dict, service: str) -> str:
    """
    Return the best node for this request, or raise HTTPException(503) if none
    currently has enough free VRAM.

    Selection criteria:
      1. Free VRAM >= model requirement + safety margin  (hard filter)
      2. Among viable nodes: lowest queue depth          (primary sort)
      3. Most free VRAM                                  (tiebreaker)
    """
    candidates = model_info["nodes"]
    required_mb = model_info["vram_mb"]
    needed_mb = required_mb + VRAM_SAFETY_MARGIN_MB

    vram_results, queue_results = await asyncio.gather(
        asyncio.gather(*[_vram_free(NODES[n]) for n in candidates]),
        asyncio.gather(*[
            _comfyui_queue_depth(NODES[n]) if service == "imagegen"
            else _ollama_active_count(NODES[n])
            for n in candidates
        ]),
    )

    viable = []
    for node_name, free_mb, queue_depth in zip(candidates, vram_results, queue_results):
        if free_mb < needed_mb:
            log.info("skip %s: %d MB free, need %d MB", node_name, free_mb, needed_mb)
        else:
            viable.append((queue_depth, -free_mb, node_name))

    if not viable:
        raise HTTPException(
            status_code=503,
            detail=(
                f"Insufficient VRAM on all eligible nodes "
                f"(need {required_mb} MB + {VRAM_SAFETY_MARGIN_MB} MB margin)."
            ),
        )

    viable.sort()
    _, _, node_name = viable[0]
    free_mb = -viable[0][1]
    log.info("routing %s → %s (vram_free=%d MB, queue=%d)", service, node_name, free_mb, viable[0][0])
    return node_name


# ---------------------------------------------------------------------------
# Job execution helpers
# ---------------------------------------------------------------------------

async def _run_imagegen(node_name: str, payload: dict) -> dict:
    api_url = NODES[node_name]["image_api_url"]
    async with httpx.AsyncClient(timeout=BACKEND_TIMEOUT) as client:
        resp = await client.post(f"{api_url}/image", json=payload)
    if not resp.is_success:
        raise HTTPException(status_code=502,
                            detail=f"imagegen backend {node_name} returned {resp.status_code}: {resp.text[:300]}")
    data = resp.json()
    data["_node"] = node_name
    return data


async def _run_llm(node_name: str, model_info: dict, body: dict) -> dict:
    backend_url = NODES[node_name]["llm_url"]
    forwarded = {**body, "model": model_info["backend_model"], "stream": False}
    async with httpx.AsyncClient(timeout=BACKEND_TIMEOUT) as client:
        resp = await client.post(f"{backend_url}/v1/chat/completions", json=forwarded)
    if not resp.is_success:
        raise HTTPException(status_code=502,
                            detail=f"LLM backend {node_name} returned {resp.status_code}: {resp.text[:300]}")
    return resp.json()


async def _process_job(job: Job) -> None:
    """
    Wait until VRAM is available, then execute the job.
    Called by the background queue worker — runs until done or failed.
    """
    # Poll until a viable node is found
    while True:
        try:
            node_name = await pick_node(job.model_info, job.service)
            break
        except HTTPException as exc:
            if exc.status_code == 503:
                log.info("job %s waiting for VRAM (retry in %ds)", job.id, QUEUE_POLL_INTERVAL)
                await asyncio.sleep(QUEUE_POLL_INTERVAL)
            else:
                job.status = JobStatus.FAILED
                job.error = str(exc.detail)
                return

    job.status = JobStatus.RUNNING
    job.node = node_name
    log.info("starting job %s on %s", job.id, node_name)

    try:
        if job.service == "imagegen":
            job.result = await _run_imagegen(node_name, job.payload)
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
    """Periodically remove completed/failed jobs older than JOB_TTL."""
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
        asyncio.create_task(_queue_worker("llm"),      name="worker-llm"),
        asyncio.create_task(_cleanup_worker(),         name="worker-cleanup"),
    ]
    log.info("background workers started")
    yield
    for w in workers:
        w.cancel()


app = FastAPI(title="Inference Proxy", version="0.2.0", lifespan=lifespan)


# ---------------------------------------------------------------------------
# Image generation — bot-compatible API
# ---------------------------------------------------------------------------

async def _enqueue_or_run_imagegen(model_name: str, payload: dict) -> tuple[dict | None, Job | None]:
    """
    Try to run immediately. If no VRAM, queue and return the Job.
    Returns (result, None) on immediate success or (None, job) when queued.
    """
    model_info = IMAGEGEN_MODELS.get(model_name)
    if not model_info:
        raise HTTPException(status_code=400, detail=f"Unknown image model: {model_name!r}. "
                            f"Available: {list(IMAGEGEN_MODELS)}")

    # Inject checkpoint filename so image-api knows which model to load
    payload = {**payload, "ckpt_name": model_info["backend_model"]}

    try:
        node_name = await pick_node(model_info, "imagegen")
        result = await _run_imagegen(node_name, payload)
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
        return JSONResponse({"job_id": job.id, "status": "queued", "position": position}, status_code=202)

    return JSONResponse(result)


@app.get("/output/{filename}")
async def proxy_output(filename: str):
    """Fetch a generated image from whichever node produced it."""
    async with httpx.AsyncClient(timeout=30.0) as client:
        for node_name, node in NODES.items():
            url = f"{node['image_api_url']}/output/{filename}"
            try:
                r = await client.get(url)
                if r.is_success:
                    log.info("serving output/%s from %s", filename, node_name)
                    return StreamingResponse(
                        iter([r.content]),
                        media_type=r.headers.get("content-type", "image/png"),
                    )
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

    # Streaming requests can't be queued — run immediately or fail
    if body.get("stream"):
        node_name = await pick_node(model_info, "llm")
        backend_url = NODES[node_name]["llm_url"]
        forwarded = {**body, "model": model_info["backend_model"]}

        async def generate():
            async with httpx.AsyncClient(timeout=BACKEND_TIMEOUT) as client:
                async with client.stream("POST", f"{backend_url}/v1/chat/completions",
                                         json=forwarded) as r:
                    async for chunk in r.aiter_bytes():
                        yield chunk

        return {"_stream": generate}, None  # caller handles StreamingResponse

    try:
        node_name = await pick_node(model_info, "llm")
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
        return JSONResponse({"job_id": job.id, "status": "queued", "position": position}, status_code=202)

    if "_stream" in result:
        return StreamingResponse(result["_stream"](), media_type="text/event-stream")

    return JSONResponse(result)


@app.post("/v1/completions")
async def completions(request: Request):
    body = await request.json()
    # Reuse chat completions path; model routing is the same
    result, job = await _enqueue_or_run_llm(body)

    if job:
        position = sum(1 for j in job_results.values() if j.status == JobStatus.QUEUED)
        return JSONResponse({"job_id": job.id, "status": "queued", "position": position}, status_code=202)

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

    if job.status == JobStatus.QUEUED:
        queued = sorted(
            (j for j in job_results.values() if j.status == JobStatus.QUEUED),
            key=lambda j: j.created_at,
        )
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
        "imagegen": {
            name: {"vram_mb": m["vram_mb"], "nodes": m["nodes"]}
            for name, m in IMAGEGEN_MODELS.items()
        },
        "llm": {
            name: {"vram_mb": m["vram_mb"], "nodes": m["nodes"]}
            for name, m in LLM_MODELS.items()
        },
    })


@app.get("/health")
async def health() -> JSONResponse:
    statuses: dict[str, Any] = {}
    async with httpx.AsyncClient(timeout=5.0) as client:
        for node_name, node in NODES.items():
            node_status: dict[str, Any] = {}
            for svc, url, probe in [
                ("imagegen", node["image_api_url"], "/health"),
                ("llm",      node["llm_url"],       "/api/tags"),
            ]:
                try:
                    r = await client.get(f"{url}{probe}")
                    node_status[svc] = "ok" if r.is_success else f"http_{r.status_code}"
                except Exception:
                    node_status[svc] = "unreachable"
            node_status["vram_free_mb"] = await _vram_free(node)
            node_status["vram_total_mb"] = node["vram_mb"]
            statuses[node_name] = node_status

    queue_status = {
        "imagegen_queued": sum(1 for j in job_results.values()
                               if j.service == "imagegen" and j.status == JobStatus.QUEUED),
        "llm_queued": sum(1 for j in job_results.values()
                          if j.service == "llm" and j.status == JobStatus.QUEUED),
    }

    return JSONResponse({"nodes": statuses, "queues": queue_status})
