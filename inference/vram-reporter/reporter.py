#!/usr/bin/env python3
"""
Minimal VRAM reporter — runs on each GPU node.
Exposes current nvidia-smi memory stats as JSON over HTTP on port 9835.
The inference proxy polls this before routing each job.

Endpoints:
  GET /vram   — current free/used/total VRAM per GPU (MiB)
  GET /health — liveness check
"""

import json
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer


PORT = 9835


def query_nvidia_smi() -> list[dict]:
    out = subprocess.check_output(
        [
            "nvidia-smi",
            "--query-gpu=index,name,memory.used,memory.free,memory.total",
            "--format=csv,noheader,nounits",
        ],
        timeout=5,
    ).decode()
    gpus = []
    for line in out.strip().splitlines():
        idx, name, used, free, total = [x.strip() for x in line.split(",", 4)]
        gpus.append(
            {
                "index": int(idx),
                "name": name,
                "memory_used_mb": int(used),
                "memory_free_mb": int(free),
                "memory_total_mb": int(total),
            }
        )
    return gpus


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # suppress per-request access logs

    def _respond(self, code: int, body: bytes, content_type: str = "application/json"):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/vram":
            try:
                gpus = query_nvidia_smi()
                self._respond(200, json.dumps({"gpus": gpus}).encode())
            except Exception as exc:
                self._respond(500, json.dumps({"error": str(exc)}).encode())
        elif self.path == "/health":
            self._respond(200, b'{"status":"ok"}')
        else:
            self._respond(404, b'{"error":"not found"}')


if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", PORT), Handler)
    print(f"VRAM reporter listening on :{PORT}")
    server.serve_forever()
