#!/usr/bin/env bash
# Provision a fresh claudebot-style LXC after terraform apply.
# Usage: ./provision.sh <container-ip>
# Requires SSH access via evilbot jump host.
set -euo pipefail

CONTAINER_IP="${1:?Usage: $0 <container-ip>}"
JUMP="root@192.168.1.145"

echo "==> Provisioning claudebot at $CONTAINER_IP"

ssh -o StrictHostKeyChecking=accept-new -J "$JUMP" "root@$CONTAINER_IP" bash << 'EOF'
set -euo pipefail

echo "--- System update ---"
apt-get update -q && apt-get upgrade -y -q

echo "--- Core tools ---"
apt-get install -y curl wget git ca-certificates gnupg

echo "--- Node.js 22 ---"
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs
node --version

echo "--- Python 3 + pip ---"
apt-get install -y python3 python3-pip python3-venv
python3 --version

echo "--- Terraform ---"
wget -q -O /tmp/hashicorp.gpg https://apt.releases.hashicorp.com/gpg
gpg --batch --no-tty --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg /tmp/hashicorp.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com bookworm main" \
  > /etc/apt/sources.list.d/hashicorp.list
apt-get update -q && apt-get install -y terraform
terraform version

echo "--- Claude Code CLI ---"
npm install -g @anthropic-ai/claude-code
claude --version

echo ""
echo "Provisioning complete."
echo "Next: configure SSH keys, clone the evilbot repo, set up secrets."
EOF

echo "==> Done. SSH in with: ssh -J $JUMP root@$CONTAINER_IP"
