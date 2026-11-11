#!/usr/bin/env python3
"""
gpu-ctl — privileged GPU lifecycle agent for gpu-desktop (gpu-desktop, RTX 3090).

The inference proxy on inferbot runs as `nobody` and can only reach HTTP
endpoints, so it can unload Ollama (keep_alive=0) and ComfyUI (/free) but can
NEVER start or stop vLLM — that is a systemd unit on this host. This agent owns
exactly the privileged bits the proxy is missing:

  * start/stop the vLLM (donnertune) systemd unit, blocking until it is actually
    serving (the ~36s cold start), then reporting how long the load took;
  * lockout mode — full teardown of every GPU service and a persistent flag so
    the operator gets the card back uninterrupted (gaming, video render);
  * a VRAM ownership breakdown (nvidia-smi per-process) so "who is holding the
    memory" is answerable.

It deliberately does NOT do ComfyUI/Ollama weight-eviction — those stay in the
proxy via their native HTTP calls. This agent is the "load the model" half; the
proxy stays the orchestrator.

Security:
  * Shared-secret bearer token (GPU_CTL_TOKEN env, or `token` in config).
    Requests without a matching `Authorization: Bearer <token>` get 401.
  * Binds 0.0.0.0 but MUST be firewalled so only inferbot can reach it. Never
    expose this port to the internet — it can stop GPU services.

Config: JSON at /etc/gpu-ctl/config.json (override with GPU_CTL_CONFIG env).
See config.example.json.

Endpoints:
  GET  /health         — liveness, no auth
  GET  /state          — {locked, vllm:{loaded,unit_active}, vram, processes}
  POST /vllm/start     — systemctl start + readiness poll; {loaded, load_seconds}
  POST /vllm/stop      — systemctl stop; {loaded:false}
  POST /lockout        — stop all services, set persistent lock flag
  POST /unlock         — clear lock flag (services stay down until loaded)
"""

import json
import os
import shlex
import subprocess
import sys
import threading
import time
import urllib.request
import urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEFAULT_CONFIG = "/etc/gpu-ctl/config.json"
DEFAULT_PORT = 9840

CONFIG_PATH = os.environ.get("GPU_CTL_CONFIG", DEFAULT_CONFIG)
TOKEN = os.environ.get("GPU_CTL_TOKEN", "")


def load_config() -> dict:
    with open(CONFIG_PATH) as f:
        return json.load(f)


CONFIG = load_config()
if not TOKEN:
    TOKEN = CONFIG.get("token", "")
PORT = int(CONFIG.get("port", DEFAULT_PORT))
# Persistent lock flag lives in /run (cleared on reboot — lockout is an
# operator convenience, not a security boundary, so that is acceptable and
# actually desirable: a reboot should hand the card back to the operator).
LOCK_FILE = CONFIG.get("lock_file", "/run/gpu-ctl.lock")
VLLM_UNIT = CONFIG.get("vllm", {}).get("unit", "vllm-donnertune")
VLLM_READY_URL = CONFIG.get("vllm", {}).get("ready_url", "http://127.0.0.1:8000/v1/models")
VLLM_READY_TIMEOUT = int(CONFIG.get("vllm", {}).get("ready_timeout_s", 300))
VLLM_ENV_FILE = CONFIG.get("vllm", {}).get("api_key_file", "/etc/vllm-donnertune.env")
VLLM_COMPLETIONS_URL = CONFIG.get("vllm", {}).get(
    "completions_url", "http://127.0.0.1:8000/v1/completions")
SERVICES = CONFIG.get("services", {})  # name -> {"start": [...], "stop": [...]}

# Gaming take-back (friend-cluster phase 1). When a game process appears, the
# watcher does an automatic lockout; when every game has been gone for
# release_grace_s it lifts ITS OWN lockout (a manual /lockout is never lifted
# automatically). Patterns are matched against /proc/<pid>/cmdline.
GAME = CONFIG.get("game_watch", {})
GAME_ENABLED = bool(GAME.get("enabled", False))
GAME_INTERVAL = float(GAME.get("interval_s", 5))
GAME_GRACE = float(GAME.get("release_grace_s", 120))
GAME_PATTERNS = [p.lower() for p in GAME.get("patterns", [
    "steamlaunch", "/steamapps/common/", "rpcs3", "prismlauncher",
    "net.minecraft", "wine64-preloader"])]
GAME_IGNORE = [p.lower() for p in GAME.get("ignore", ["steamwebhelper"])]

# Idle stop: vLLM holds ~21 GB even when nobody calls it. Stop it after
# idle_minutes with no new requests (counter read from vLLM /metrics); the
# next /vllm/completions starts it again (~36 s cold start).
IDLE = CONFIG.get("idle_stop", {})
IDLE_ENABLED = bool(IDLE.get("enabled", False))
IDLE_SECONDS = float(IDLE.get("idle_minutes", 30)) * 60
VLLM_METRICS_URL = CONFIG.get("vllm", {}).get("metrics_url", "http://127.0.0.1:8000/metrics")
AUTOSTART = bool(CONFIG.get("autostart_on_request", True))

# Lock reason: "manual" (operator /lockout) or "game" (watcher). Kept beside
# the lock file so a gpu-ctl restart doesn't forget who set it.
LOCK_REASON_FILE = LOCK_FILE + ".reason"
_last_activity = time.monotonic()
_last_req_count = None
_watch_status = {"games": [], "last_check": None, "events": []}

_STATE_LOCK = threading.Lock()


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def vllm_api_key() -> str:
    """Read VLLM_API_KEY from the env file so the readiness probe can auth."""
    try:
        with open(VLLM_ENV_FILE) as f:
            for line in f:
                line = line.strip()
                if line.startswith("VLLM_API_KEY="):
                    return line.split("=", 1)[1].strip()
    except FileNotFoundError:
        pass
    return ""


def run(cmd: list[str], timeout: int = 60) -> tuple[int, str, str]:
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout, p.stderr


def systemctl(verb: str, unit: str) -> None:
    code, out, err = run(["systemctl", verb, unit], timeout=120)
    if code != 0:
        raise RuntimeError(f"systemctl {verb} {unit} failed: {err or out}")


def nvidia_smi_vram() -> dict:
    out = subprocess.check_output(
        ["nvidia-smi", "--query-gpu=index,name,memory.used,memory.free,memory.total",
         "--format=csv,noheader,nounits"], timeout=5).decode()
    gpus = []
    for line in out.strip().splitlines():
        idx, name, used, free, total = [x.strip() for x in line.split(",", 4)]
        gpus.append({"index": int(idx), "name": name, "memory_used_mb": int(used),
                     "memory_free_mb": int(free), "memory_total_mb": int(total)})
    return {"gpus": gpus, "memory_free_mb": sum(g["memory_free_mb"] for g in gpus)}


def nvidia_smi_processes() -> list[dict]:
    """Which compute processes are holding VRAM, and how much."""
    try:
        out = subprocess.check_output(
            ["nvidia-smi", "--query-compute-apps=pid,process_name,used_memory",
             "--format=csv,noheader,nounits"], timeout=5).decode()
    except subprocess.CalledProcessError:
        return []
    procs = []
    for line in out.strip().splitlines():
        if not line:
            continue
        pid, name, used = [x.strip() for x in line.split(",", 2)]
        procs.append({"pid": int(pid), "name": name, "used_mb": int(used)})
    return procs


def locked() -> bool:
    return os.path.exists(LOCK_FILE)


def set_locked(val: bool, reason: str = "manual") -> None:
    if val:
        open(LOCK_FILE, "w").close()
        with open(LOCK_REASON_FILE, "w") as f:
            f.write(reason)
    else:
        for path in (LOCK_FILE, LOCK_REASON_FILE):
            try:
                os.remove(path)
            except FileNotFoundError:
                pass


def lock_reason() -> str | None:
    if not locked():
        return None
    try:
        with open(LOCK_REASON_FILE) as f:
            return f.read().strip() or "manual"
    except FileNotFoundError:
        return "manual"


def _event(msg: str) -> None:
    line = time.strftime("%Y-%m-%dT%H:%M:%S") + " " + msg
    print(line, flush=True)
    _watch_status["events"] = (_watch_status["events"] + [line])[-20:]


def vllm_unit_active() -> bool:
    code, _, _ = run(["systemctl", "is-active", "--quiet", VLLM_UNIT], timeout=15)
    return code == 0


def vllm_ready() -> bool:
    req = urllib.request.Request(VLLM_READY_URL)
    key = vllm_api_key()
    if key:
        req.add_header("Authorization", f"Bearer {key}")
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status == 200
    except Exception:
        return False


def start_vllm() -> dict:
    """Start the unit and block until it serves. Returns {loaded, load_seconds}."""
    if vllm_ready():
        return {"loaded": True, "load_seconds": 0.0, "already_loaded": True}
    with _STATE_LOCK:
        t0 = time.monotonic()
        systemctl("start", VLLM_UNIT)
        deadline = t0 + VLLM_READY_TIMEOUT
        while time.monotonic() < deadline:
            if vllm_ready():
                return {"loaded": True,
                        "load_seconds": round(time.monotonic() - t0, 1),
                        "already_loaded": False}
            time.sleep(1.0)
    raise RuntimeError(
        f"vLLM did not become ready within {VLLM_READY_TIMEOUT}s of start")


def stop_vllm() -> dict:
    with _STATE_LOCK:
        systemctl("stop", VLLM_UNIT)
    return {"loaded": False}


def do_lockout(reason: str = "manual") -> dict:
    stopped = []
    with _STATE_LOCK:
        # vLLM first (largest resident), then the services the operator listed.
        if vllm_unit_active():
            systemctl("stop", VLLM_UNIT)
            stopped.append(VLLM_UNIT)
        for name, svc in SERVICES.items():
            code, _, err = run(svc.get("stop", []), timeout=120)
            if code == 0:
                stopped.append(name)
            else:
                # non-zero from `systemctl stop` on an already-stopped unit is
                # fine; surface only genuine failures.
                if "inactive" not in (err or "") and "not loaded" not in (err or ""):
                    stopped.append(f"{name}(failed: {err or 'rc=%d' % code})")
        set_locked(True, reason)
    return {"locked": True, "reason": reason, "stopped": stopped}


def do_unlock() -> dict:
    set_locked(False)
    return {"locked": False}


def vllm_completions(payload: dict) -> tuple[int, dict]:
    """Forward a raw /v1/completions request to vLLM, injecting the API key.

    The key lives only on this host (in the env file); the proxy never sees it.
    If vLLM is down (idle-stopped) it is started first, unless the card is
    locked out (gaming): then 503 with retry_after so callers back off.
    """
    global _last_activity
    _last_activity = time.monotonic()
    if not vllm_ready():
        if locked():
            return 503, {"error": "gpu locked out", "reason": lock_reason(),
                         "retry_after_s": int(GAME_GRACE)}
        if not AUTOSTART:
            return 503, {"error": "vllm not loaded"}
        try:
            start_vllm()
        except Exception as exc:
            return 503, {"error": f"vllm start failed: {exc}"}
    body = json.dumps(payload).encode()
    req = urllib.request.Request(
        VLLM_COMPLETIONS_URL, data=body, method="POST",
        headers={"Content-Type": "application/json"})
    key = vllm_api_key()
    if key:
        req.add_header("Authorization", f"Bearer {key}")
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            return r.status, json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        return e.code, {"error": e.read().decode()[:500]}
    except Exception as exc:
        return 502, {"error": str(exc)}


# ---------------------------------------------------------------------------
# watchers: gaming take-back + idle stop
# ---------------------------------------------------------------------------

def running_games() -> list[str]:
    hits = []
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                cmd = f.read().replace(b"\0", b" ").decode(errors="replace").lower()
        except OSError:
            continue
        if not cmd or any(i in cmd for i in GAME_IGNORE):
            continue
        for pat in GAME_PATTERNS:
            if pat in cmd:
                hits.append(f"{pid}:{pat}")
                break
    return hits


def vllm_request_count() -> float | None:
    """Total requests vLLM has seen (success + running + waiting)."""
    try:
        with urllib.request.urlopen(VLLM_METRICS_URL, timeout=3) as r:
            text = r.read().decode()
    except Exception:
        return None
    total = 0.0
    for line in text.splitlines():
        if line.startswith(("vllm:request_success_total", "vllm:num_requests_running",
                            "vllm:num_requests_waiting")):
            try:
                total += float(line.rsplit(" ", 1)[1])
            except ValueError:
                pass
    return total


def watch_loop() -> None:
    global _last_activity, _last_req_count
    gone_since = None
    while True:
        try:
            now = time.monotonic()
            if GAME_ENABLED:
                games = running_games()
                _watch_status["games"] = games
                reason = lock_reason()
                if games:
                    gone_since = None
                    if reason is None:
                        r = do_lockout("game")
                        _event(f"game detected {games[:3]} -> lockout, stopped {r['stopped']}")
                elif reason == "game":
                    gone_since = gone_since or now
                    if now - gone_since >= GAME_GRACE:
                        do_unlock()
                        gone_since = None
                        _event("no game for %ds -> unlocked (vLLM starts on next request)" % GAME_GRACE)
            if IDLE_ENABLED and not locked():
                n = vllm_request_count()
                if n is not None and n != _last_req_count:
                    _last_req_count = n
                    _last_activity = now
                if n is not None and vllm_unit_active() and now - _last_activity >= IDLE_SECONDS:
                    stop_vllm()
                    _event("vLLM idle %d min -> stopped" % (IDLE_SECONDS // 60))
            _watch_status["last_check"] = time.strftime("%Y-%m-%dT%H:%M:%S")
        except Exception as exc:
            _event(f"watch error: {exc}")
        time.sleep(GAME_INTERVAL)


def build_state() -> dict:
    return {
        "locked": locked(),
        "lock_reason": lock_reason(),
        "watch": {"game_watch": GAME_ENABLED, "idle_stop": IDLE_ENABLED,
                  "idle_s": round(time.monotonic() - _last_activity), **_watch_status},
        "vllm": {"unit": VLLM_UNIT, "unit_active": vllm_unit_active(),
                 "loaded": vllm_ready()},
        "vram": nvidia_smi_vram(),
        "processes": nvidia_smi_processes(),
    }


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _authed(self) -> bool:
        if not TOKEN:
            return True  # no token configured -> agent is open (dev only)
        auth = self.headers.get("Authorization", "")
        return auth == f"Bearer {TOKEN}"

    def _send(self, code: int, obj, ct: str = "application/json"):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", ct)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self) -> dict:
        n = int(self.headers.get("Content-Length", 0))
        return json.loads(self.rfile.read(n)) if n else {}

    def _route(self):
        if self.path == "/health":
            return self._send(200, {"status": "ok"})

        if not self._authed():
            return self._send(401, {"error": "unauthorized"})

        if self.path == "/state":
            return self._send(200, build_state())

        handlers = {
            "/vllm/start": start_vllm,
            "/vllm/stop": stop_vllm,
            "/lockout": do_lockout,
            "/unlock": do_unlock,
        }
        # /vllm/completions is the only body-reading endpoint
        if self.path == "/vllm/completions":
            try:
                payload = self._body()
                status, result = vllm_completions(payload)
                return self._send(status, result)
            except Exception as exc:
                return self._send(500, {"error": str(exc)})
        fn = handlers.get(self.path)
        if fn is None:
            return self._send(404, {"error": "not found"})
        try:
            return self._send(200, fn())
        except Exception as exc:
            return self._send(500, {"error": str(exc)})

    def do_GET(self):
        self._route()

    def do_POST(self):
        self._route()


def main():
    if not TOKEN:
        print("WARNING: no GPU_CTL_TOKEN set and no token in config — agent is unauthenticated",
              file=sys.stderr)
    if GAME_ENABLED or IDLE_ENABLED:
        threading.Thread(target=watch_loop, daemon=True).start()
    srv = ThreadingHTTPServer((CONFIG.get("bind", "0.0.0.0"), PORT), Handler)
    print(f"gpu-ctl listening on :{PORT}")
    srv.serve_forever()


if __name__ == "__main__":
    main()
