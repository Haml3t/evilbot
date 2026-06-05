import os
import time
import json
import glob
import requests
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from pathlib import Path
from pydantic import BaseModel
from typing import Any, Optional
import asyncio

# Serialize all generations (one at a time)
GEN_LOCK = asyncio.Lock()

# Optional: cap queue to avoid runaway
MAX_QUEUE = int(os.environ.get("MAX_QUEUE", "20"))
WAITERS = 0

# Backend selection
PRIMARY_COMFYUI = os.environ.get("PRIMARY_COMFYUI_URL")  # e.g. http://192.168.1.50:8288
FALLBACK_COMFYUI = os.environ.get("FALLBACK_COMFYUI_URL", "http://comfyui:8188")  # local docker service
SASHAY_GATE_URL = os.environ.get("SASHAY_GATE_URL")  # e.g. http://192.168.1.50:8799/can_accept

# Back-compat: if COMFYUI_URL is set, treat it as FALLBACK unless explicit vars provided
COMFYUI_ENV = os.environ.get("COMFYUI_URL")
if COMFYUI_ENV and not FALLBACK_COMFYUI:
    FALLBACK_COMFYUI = COMFYUI_ENV

WORKFLOW_PATH = os.environ.get("WORKFLOW_PATH", "/workflows/starter_t2i.json")
OUTPUT_DIR = os.environ.get("OUTPUT_DIR", "/output")  # host-mounted output dir
POLL_SECONDS = float(os.environ.get("POLL_SECONDS", "0.5"))
POLL_TIMEOUT = int(os.environ.get("POLL_TIMEOUT", "180"))

# Networking timeouts
PROMPT_TIMEOUT_S = float(os.environ.get("PROMPT_TIMEOUT_S", "30"))
HISTORY_TIMEOUT_S = float(os.environ.get("HISTORY_TIMEOUT_S", "10"))
VIEW_TIMEOUT_S = float(os.environ.get("VIEW_TIMEOUT_S", "60"))
PRIMARY_CONNECT_TIMEOUT_S = float(os.environ.get("PRIMARY_CONNECT_TIMEOUT_S", "2.0"))

app = FastAPI()

class ImageReq(BaseModel):
    prompt: str
    negative: str = "lowres, blurry"
    seed: int | None = None
    width: int = 512
    height: int = 512
    steps: int | None = None
    cfg: float | None = None
    ckpt_name: str | None = None  # checkpoint filename; overrides workflow default

def load_workflow() -> dict:
    with open(WORKFLOW_PATH, "r", encoding="utf-8") as f:
        return json.load(f)

def set_inputs(wf: dict, req: ImageReq) -> dict:
    """
    Heuristic approach:
    - Prefer CLIPTextEncode nodes by title to map positive vs negative.
    - Set EmptyLatentImage width/height.
    - Set KSampler seed/steps/cfg if requested.
    - Force SaveImage filename_prefix unique each request (prevents cached runs from not writing files).
    """
    clip_nodes: list[dict[str, Any]] = []
    latent_nodes: list[dict[str, Any]] = []
    ksampler_nodes: list[dict[str, Any]] = []
    saveimage_nodes: list[dict[str, Any]] = []
    checkpoint_nodes: list[dict] = []

    for _, node in wf.items():
        if not isinstance(node, dict):
            continue
        ct = node.get("class_type")
        if ct == "CLIPTextEncode":
            clip_nodes.append(node)
        elif ct == "EmptyLatentImage":
            latent_nodes.append(node)
        elif ct == "KSampler":
            ksampler_nodes.append(node)
        elif ct == "SaveImage":
            saveimage_nodes.append(node)
        elif ct == "CheckpointLoaderSimple":
            checkpoint_nodes.append(node)

    if not clip_nodes:
        raise ValueError("No CLIPTextEncode nodes found in workflow JSON")

    def title_of(n: dict) -> str:
        meta = n.get("_meta") or {}
        return str(meta.get("title", "")).lower()

    positive = None
    negative = None
    for n in clip_nodes:
        t = title_of(n)
        if positive is None and any(k in t for k in ["positive", "prompt"]):
            positive = n
        if negative is None and "negative" in t:
            negative = n

    if positive is None:
        positive = clip_nodes[0]
    if negative is None and len(clip_nodes) >= 2:
        negative = clip_nodes[1]

    positive.setdefault("inputs", {})
    positive["inputs"]["text"] = req.prompt

    if negative is not None:
        negative.setdefault("inputs", {})
        negative["inputs"]["text"] = req.negative

    if latent_nodes:
        latent = latent_nodes[0]
        latent.setdefault("inputs", {})
        latent["inputs"]["width"] = int(req.width)
        latent["inputs"]["height"] = int(req.height)

    if ksampler_nodes:
        ks_inputs = ksampler_nodes[0].setdefault("inputs", {})
        if req.seed is not None:
            ks_inputs["seed"] = int(req.seed)
        if req.steps is not None:
            ks_inputs["steps"] = int(req.steps)
        if req.cfg is not None:
            ks_inputs["cfg"] = float(req.cfg)

    if req.ckpt_name and checkpoint_nodes:
        for ck in checkpoint_nodes:
            ck.setdefault("inputs", {})
            ck["inputs"]["ckpt_name"] = req.ckpt_name

    # Force unique output prefix so SaveImage writes a new file every request
    if saveimage_nodes:
        prefix = f"api_{int(time.time())}"
        for s in saveimage_nodes:
            s.setdefault("inputs", {})
            s["inputs"]["filename_prefix"] = prefix

    return wf

def can_use_primary() -> bool:
    if not PRIMARY_COMFYUI:
        return False
    if not SASHAY_GATE_URL:
        # no gate configured: allow trying primary, but it may fail and fall back
        return True
    try:
        r = requests.get(SASHAY_GATE_URL, timeout=PRIMARY_CONNECT_TIMEOUT_S)
        data = r.json()
        return bool(data.get("ok"))
    except Exception:
        return False

def comfy_post_prompt(base: str, graph: dict) -> str:
    r = requests.post(f"{base}/prompt", json={"prompt": graph}, timeout=PROMPT_TIMEOUT_S)
    if r.status_code != 200:
        raise HTTPException(status_code=502, detail=f"ComfyUI /prompt failed ({base}): {r.text[:400]}")
    return r.json()["prompt_id"]

def comfy_get_history(base: str, prompt_id: str) -> dict:
    r = requests.get(f"{base}/history/{prompt_id}", timeout=HISTORY_TIMEOUT_S)
    if r.status_code != 200:
        return {}
    return r.json()

def comfy_download_view_to_output(base: str, filename: str, out_name: Optional[str] = None) -> str:
    """
    Downloads a ComfyUI output image via /view and saves into OUTPUT_DIR.
    Returns the saved filename (safe, local).
    """
    safe_remote = os.path.basename(filename)
    local_name = out_name or safe_remote
    local_name = os.path.basename(local_name)

    params = {"filename": safe_remote, "subfolder": "", "type": "output"}
    r = requests.get(f"{base}/view", params=params, timeout=VIEW_TIMEOUT_S)
    if r.status_code != 200:
        raise HTTPException(status_code=502, detail=f"ComfyUI /view failed ({base}): {r.text[:200]}")

    out_path = Path(OUTPUT_DIR) / local_name
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_bytes(r.content)
    return local_name

def extract_filenames_from_history(hist: dict, prompt_id: str) -> list[str]:
    item = hist.get(prompt_id, {})
    outputs = item.get("outputs", {})
    images = []
    for out in outputs.values():
        for img in out.get("images", []):
            fn = img.get("filename")
            if fn:
                images.append(fn)
    return images

def list_recent_outputs(since_seconds: int = 600) -> list[str]:
    patterns = [
        os.path.join(OUTPUT_DIR, "*.png"),
        os.path.join(OUTPUT_DIR, "*.jpg"),
        os.path.join(OUTPUT_DIR, "*.jpeg"),
    ]
    files = []
    now = time.time()
    for pat in patterns:
        for p in glob.glob(pat):
            try:
                st = os.stat(p)
                if now - st.st_mtime <= since_seconds:
                    files.append((st.st_mtime, p))
            except FileNotFoundError:
                pass
    return [p for _, p in sorted(files, reverse=True)]

@app.post("/image")
async def make_image(req: ImageReq):
    global WAITERS

    if WAITERS >= MAX_QUEUE:
        raise HTTPException(status_code=429, detail="Too many queued requests, try again soon")

    WAITERS += 1
    try:
        async with GEN_LOCK:
            wf = load_workflow()
            try:
                wf = set_inputs(wf, req)
            except ValueError as e:
                raise HTTPException(status_code=400, detail=str(e))

            # Choose backend
            backends: list[str] = []
            if can_use_primary():
                backends.append(PRIMARY_COMFYUI)  # type: ignore[arg-type]
            backends.append(FALLBACK_COMFYUI)

            last_err: Optional[str] = None

            for base in backends:
                try:
                    # Send prompt
                    prompt_id = await asyncio.to_thread(comfy_post_prompt, base, wf)

                    # Poll history
                    deadline = time.time() + POLL_TIMEOUT
                    last_history = {}
                    while time.time() < deadline:
                        hist = await asyncio.to_thread(comfy_get_history, base, prompt_id)
                        last_history = hist
                        if hist:
                            images = extract_filenames_from_history(hist, prompt_id)
                            if images:
                                # Ensure image is available locally under /output
                                # (important for remote comfyui backends)
                                saved = await asyncio.to_thread(
                                    comfy_download_view_to_output, base, images[0]
                                )
                                return {"prompt_id": prompt_id, "images": [saved], "history": hist.get(prompt_id, {})}

                        await asyncio.sleep(POLL_SECONDS)

                    # Timeout: attempt fallback by checking recent remote outputs (not reliable),
                    # so we just record error and try next backend.
                    last_err = f"timeout waiting for outputs from {base} (prompt_id={prompt_id})"
                except Exception as e:
                    last_err = str(e)

            # If we got here, all backends failed
            recent = list_recent_outputs()
            raise HTTPException(status_code=502, detail=f"All backends failed. last_error={last_err}. recent_local={recent[:2]}")

    finally:
        WAITERS -= 1

@app.get("/output/{filename}")
def get_output(filename: str):
    safe = os.path.basename(filename)
    path = Path(OUTPUT_DIR) / safe
    if not path.exists():
        raise HTTPException(status_code=404, detail="file not found")
    return FileResponse(path)



@app.get("/health")
def health():
    return {"status": "ok", "workflow": WORKFLOW_PATH, "output_dir": OUTPUT_DIR}
