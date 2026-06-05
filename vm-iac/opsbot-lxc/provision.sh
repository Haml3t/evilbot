#!/usr/bin/env bash
# Provision a fresh opsbot LXC after terraform apply.
# Installs the GitHub Actions self-hosted runner and wires up SSH access
# to all deploy targets.
#
# Usage:
#   ./provision.sh <container-ip> <github-runner-token>
#
# Get the runner token from:
#   GitHub repo → Settings → Actions → Runners → New self-hosted runner
#   Copy the token from the --token flag in the "Configure" step.
#
# Requires SSH access to opsbot via jump host (claudebot key must be in
# opsbot's authorized_keys — handled by terraform via ssh_public_key).
set -euo pipefail

CONTAINER_IP="${1:?Usage: $0 <container-ip> <github-runner-token>}"
RUNNER_TOKEN="${2:?Usage: $0 <container-ip> <github-runner-token>}"
REPO_URL="https://github.com/Haml3t/evilbot"
JUMP="root@192.168.1.145"
RUNNER_VERSION="2.325.0"

# Deploy targets — must match the SSH config written below
INFERBOT_IP="192.168.1.223"
TELEGRAM_IP="192.168.1.238"
GPU_DESKTOP_IP="192.168.1.12"
GPU_DESKTOP_USER="<user>"   # replace with actual username on gpu-desktop

echo "==> Provisioning opsbot at $CONTAINER_IP"

ssh -o StrictHostKeyChecking=accept-new -J "$JUMP" "root@$CONTAINER_IP" bash << 'REMOTE'
set -euo pipefail

echo "--- System update ---"
apt-get update -q && apt-get upgrade -y -q
apt-get install -y curl wget git ca-certificates openssh-client jq

echo "--- Generate opsbot SSH key ---"
if [[ ! -f /root/.ssh/id_ed25519 ]]; then
  ssh-keygen -t ed25519 -C "opsbot-deploy" -N "" -f /root/.ssh/id_ed25519
fi
echo "opsbot public key:"
cat /root/.ssh/id_ed25519.pub

echo "--- Create GitHub Actions runner user ---"
id runner &>/dev/null || useradd -m -s /bin/bash runner
mkdir -p /home/runner/.ssh
cp /root/.ssh/id_ed25519 /root/.ssh/id_ed25519.pub /home/runner/.ssh/
chown -R runner:runner /home/runner/.ssh
chmod 700 /home/runner/.ssh
chmod 600 /home/runner/.ssh/id_ed25519

REMOTE

echo "==> Writing SSH config for deploy targets..."
ssh -J "$JUMP" "root@$CONTAINER_IP" bash << REMOTE
set -euo pipefail
cat > /home/runner/.ssh/config << 'SSHCONF'
Host evilbot
  HostName 192.168.1.145
  User root
  StrictHostKeyChecking accept-new

Host inferbot
  HostName $INFERBOT_IP
  User root
  StrictHostKeyChecking accept-new

Host evilbot-telegram
  HostName $TELEGRAM_IP
  User root
  ProxyJump evilbot
  StrictHostKeyChecking accept-new

Host gpu-desktop
  HostName $GPU_DESKTOP_IP
  User $GPU_DESKTOP_USER
  ProxyJump evilbot
  StrictHostKeyChecking accept-new
SSHCONF
chown runner:runner /home/runner/.ssh/config
chmod 600 /home/runner/.ssh/config
REMOTE

echo "==> Distributing opsbot pubkey to deploy targets..."
OPSBOT_PUBKEY=$(ssh -J "$JUMP" "root@$CONTAINER_IP" cat /root/.ssh/id_ed25519.pub)

# inferbot — direct SSH
ssh -o StrictHostKeyChecking=accept-new -J "$JUMP" "root@$INFERBOT_IP" \
  "mkdir -p ~/.ssh && echo '$OPSBOT_PUBKEY' >> ~/.ssh/authorized_keys && sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys"
echo "  ✓ inferbot"

# evilbot host (needed as jump host for telegram + gpu-desktop)
ssh -o StrictHostKeyChecking=accept-new "root@$JUMP" \
  "echo '$OPSBOT_PUBKEY' >> /root/.ssh/authorized_keys && sort -u /root/.ssh/authorized_keys -o /root/.ssh/authorized_keys" 2>/dev/null || \
ssh "root@192.168.1.145" \
  "echo '$OPSBOT_PUBKEY' >> /root/.ssh/authorized_keys && sort -u /root/.ssh/authorized_keys -o /root/.ssh/authorized_keys"
echo "  ✓ evilbot (jump host)"

# evilbot-telegram via jump
ssh -o StrictHostKeyChecking=accept-new -J "$JUMP" "root@$TELEGRAM_IP" \
  "mkdir -p ~/.ssh && echo '$OPSBOT_PUBKEY' >> ~/.ssh/authorized_keys && sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys"
echo "  ✓ evilbot-telegram"

echo ""
echo "  ⚠  gpu-desktop requires manual step — run this on your desktop:"
echo "     echo '$OPSBOT_PUBKEY' >> ~/.ssh/authorized_keys"
echo ""

echo "==> Installing GitHub Actions runner (v${RUNNER_VERSION})..."
ssh -J "$JUMP" "root@$CONTAINER_IP" bash << REMOTE
set -euo pipefail
cd /home/runner
ARCH=\$(dpkg --print-architecture)
[[ "\$ARCH" == "amd64" ]] && ARCH="x64"
RUNNER_ARCHIVE="actions-runner-linux-\${ARCH}-${RUNNER_VERSION}.tar.gz"

wget -q "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/\$RUNNER_ARCHIVE"
tar xzf "\$RUNNER_ARCHIVE"
rm "\$RUNNER_ARCHIVE"
chown -R runner:runner /home/runner
REMOTE

echo "==> Registering runner with GitHub..."
ssh -J "$JUMP" "root@$CONTAINER_IP" bash << REMOTE
set -euo pipefail
cd /home/runner
su -s /bin/bash runner -c "./config.sh --url $REPO_URL --token $RUNNER_TOKEN --name opsbot --labels opsbot,self-hosted,Linux,X64 --work _work --unattended"
REMOTE

echo "==> Installing runner as systemd service..."
ssh -J "$JUMP" "root@$CONTAINER_IP" bash << 'REMOTE'
set -euo pipefail
cd /home/runner
./svc.sh install runner
./svc.sh start
sleep 2
./svc.sh status
REMOTE

echo ""
echo "==> opsbot provisioned successfully."
echo ""
echo "Next steps:"
echo "  1. Add opsbot pubkey to gpu-desktop (see above)"
echo "  2. Verify runner appears online: GitHub repo → Settings → Actions → Runners"
echo "  3. Push a change to inference/proxy/, telegram-bot/, or inference/image-api/ to test"
