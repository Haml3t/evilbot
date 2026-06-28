#!/usr/bin/env bash
# Install the VRAM reporter on a GPU node (evilbot host or gpu-desktop).
# Run as root on the target machine.
#
# Usage (from evilbot-repo root):
#   On evilbot:  ssh root@192.168.0.145 'bash -s' < inference/vram-reporter/install.sh
#   On gpu-desktop:   ssh <user>@192.168.0.12 'sudo bash -s' < inference/vram-reporter/install.sh
set -euo pipefail

INSTALL_DIR="/opt/vram-reporter"
SERVICE_FILE="/etc/systemd/system/vram-reporter.service"
REPORTER_URL="https://raw.githubusercontent.com/..."  # update if publishing to GitHub

echo "==> Installing VRAM reporter"

# Create unprivileged user in the video group (video group can read /dev/nvidia*)
id vram-reporter &>/dev/null || useradd -r -s /bin/false -G video vram-reporter

mkdir -p "$INSTALL_DIR"

# Copy files (assumes script is run from repo root via pipe, so use heredoc)
cat > "$INSTALL_DIR/reporter.py" << 'PYEOF'
#!/usr/bin/env python3
import json, subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = 9835

def query_nvidia_smi():
    out = subprocess.check_output(
        ["nvidia-smi",
         "--query-gpu=index,name,memory.used,memory.free,memory.total",
         "--format=csv,noheader,nounits"],
        timeout=5,
    ).decode()
    gpus = []
    for line in out.strip().splitlines():
        idx, name, used, free, total = [x.strip() for x in line.split(",", 4)]
        gpus.append({"index": int(idx), "name": name,
                     "memory_used_mb": int(used), "memory_free_mb": int(free),
                     "memory_total_mb": int(total)})
    return gpus

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def _respond(self, code, body, ct="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ct)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        if self.path == "/vram":
            try: self._respond(200, json.dumps({"gpus": query_nvidia_smi()}).encode())
            except Exception as e: self._respond(500, json.dumps({"error": str(e)}).encode())
        elif self.path == "/health": self._respond(200, b'{"status":"ok"}')
        else: self._respond(404, b'{"error":"not found"}')

HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
PYEOF

cat > "$SERVICE_FILE" << 'SVCEOF'
[Unit]
Description=VRAM reporter for inference proxy
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/vram-reporter/reporter.py
Restart=always
RestartSec=5
User=vram-reporter
Group=video
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadOnlyPaths=/

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable --now vram-reporter

echo "==> Verifying..."
sleep 2
curl -sf http://127.0.0.1:9835/vram | python3 -m json.tool
echo "==> VRAM reporter installed and running on :9835"
