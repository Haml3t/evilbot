#!/usr/bin/env bash
# Provision evilbot-telegram after terraform apply (or after a fresh Ubuntu install).
# Usage: ./provision.sh <vm-ip>
# Secrets: copy .env.example to /opt/evilbot/.env on the VM and fill in real values.
set -euo pipefail

VM_IP="${1:?Usage: $0 <vm-ip>}"
JUMP="root@192.168.1.145"
BOT_SRC="$(dirname "$0")/../../telegram-bot"

echo "==> Provisioning evilbot-telegram at $VM_IP"

# Copy bot source to VM
echo "--- Copying bot source ---"
scp -J "$JUMP" "$BOT_SRC/evilbot.py" "$BOT_SRC/requirements.txt" "ubuntu@$VM_IP:/tmp/"

ssh -o StrictHostKeyChecking=accept-new -J "$JUMP" "ubuntu@$VM_IP" bash << 'EOF'
set -euo pipefail

echo "--- System update ---"
sudo apt-get update -q && sudo apt-get upgrade -y -q

echo "--- Python 3 + venv ---"
sudo apt-get install -y python3 python3-venv python3-pip

echo "--- Create evilbot user and directory ---"
sudo useradd -r -s /bin/false -d /opt/evilbot evilbot 2>/dev/null || echo "user exists"
sudo mkdir -p /opt/evilbot
sudo cp /tmp/evilbot.py /tmp/requirements.txt /opt/evilbot/

echo "--- Python venv + dependencies ---"
sudo python3 -m venv /opt/evilbot/venv
sudo /opt/evilbot/venv/bin/pip install -q -r /opt/evilbot/requirements.txt

echo "--- Systemd service ---"
sudo tee /etc/systemd/system/evilbot.service > /dev/null << 'SERVICE'
[Unit]
Description=Evilbot Telegram Service
After=network.target tailscaled.service

[Service]
Type=simple
User=evilbot
WorkingDirectory=/opt/evilbot
EnvironmentFile=/opt/evilbot/.env
ExecStart=/opt/evilbot/venv/bin/python /opt/evilbot/evilbot.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE

echo "--- Permissions ---"
sudo chown -R evilbot:evilbot /opt/evilbot
sudo chmod 750 /opt/evilbot

sudo systemctl daemon-reload
sudo systemctl enable evilbot

echo ""
echo "IMPORTANT: Create /opt/evilbot/.env before starting the service:"
echo "  TELEGRAM_BOT_TOKEN=<token>"
echo "  IMAGEGEN_URL=http://<tailscale-ip>:5005"
echo ""
echo "Then: sudo systemctl start evilbot"
EOF

echo "==> Done. Copy .env to the VM then start the service."
echo "    scp -J $JUMP .env ubuntu@$VM_IP:/tmp/ && ssh -J $JUMP ubuntu@$VM_IP 'sudo mv /tmp/.env /opt/evilbot/.env && sudo chown evilbot:evilbot /opt/evilbot/.env && sudo chmod 600 /opt/evilbot/.env && sudo systemctl start evilbot'"
