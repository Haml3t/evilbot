#!/usr/bin/env bash
# Provision a fresh inferbot LXC after terraform apply.
# Installs Nomad server and the inference routing proxy.
# Usage: ./provision.sh <container-ip> <evilbot-repo-path>
# Requires SSH access via evilbot jump host.
set -euo pipefail

CONTAINER_IP="${1:?Usage: $0 <container-ip> [repo-path]}"
REPO_PATH="${2:-/root/evilbot-repo}"
JUMP="root@192.168.1.145"

echo "==> Provisioning inferbot at $CONTAINER_IP"

ssh -o StrictHostKeyChecking=accept-new -J "$JUMP" "root@$CONTAINER_IP" bash << 'REMOTE'
set -euo pipefail

echo "--- System update ---"
apt-get update -q && apt-get upgrade -y -q
apt-get install -y curl wget git ca-certificates gnupg python3 python3-pip python3-venv

echo "--- Nomad ---"
wget -q -O /tmp/hashicorp.gpg https://apt.releases.hashicorp.com/gpg
gpg --batch --no-tty --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg /tmp/hashicorp.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com bookworm main" \
  > /etc/apt/sources.list.d/hashicorp.list
apt-get update -q && apt-get install -y nomad
mkdir -p /opt/nomad/data
nomad version

echo "--- Python venv for proxy ---"
python3 -m venv /opt/proxy-venv
/opt/proxy-venv/bin/pip install --quiet --upgrade pip
echo ""
echo "Provisioning complete."
echo "Next steps:"
echo "  1. Copy inference/nomad/server.hcl to /etc/nomad.d/server.hcl"
echo "  2. Copy inference/proxy/ to /opt/inference-proxy/"
echo "  3. Run: /opt/proxy-venv/bin/pip install -r /opt/inference-proxy/requirements.txt"
echo "  4. systemctl enable --now nomad"
REMOTE

echo "==> Copying Nomad server config and proxy code..."
scp -o StrictHostKeyChecking=accept-new -J "$JUMP" \
  "$REPO_PATH/inference/nomad/server.hcl" \
  "root@$CONTAINER_IP:/etc/nomad.d/server.hcl"

scp -o StrictHostKeyChecking=accept-new -J "$JUMP" -r \
  "$REPO_PATH/inference/proxy/" \
  "root@$CONTAINER_IP:/opt/inference-proxy/"

ssh -J "$JUMP" "root@$CONTAINER_IP" bash << 'REMOTE2'
set -euo pipefail
/opt/proxy-venv/bin/pip install --quiet -r /opt/inference-proxy/requirements.txt
echo "==> Proxy dependencies installed."

# Enable Nomad (server.hcl must be in place first)
systemctl enable --now nomad
sleep 3
nomad server members || true
echo "==> Done. SSH in with: ssh -J root@192.168.1.145 root@$1"
REMOTE2

echo "==> inferbot provisioned. SSH: ssh -J $JUMP root@$CONTAINER_IP"
