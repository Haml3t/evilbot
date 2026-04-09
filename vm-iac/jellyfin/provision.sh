#!/usr/bin/env bash
# Run after terraform apply to install Jellyfin on the new container.
# Usage: ./provision.sh <container-ip>
# Requires SSH access to the container via evilbot jump host.
set -euo pipefail

JELLYFIN_IP="${1:?Usage: $0 <container-ip>}"
JUMP="root@192.168.1.145"

ssh -J "$JUMP" "root@$JELLYFIN_IP" bash << 'EOF'
set -euo pipefail

echo "--- Installing Jellyfin ---"
apt-get update -q
apt-get install -y curl gnupg

curl -fsSL https://repo.jellyfin.org/jellyfin_team.gpg.key \
  | gpg --dearmor -o /usr/share/keyrings/jellyfin.gpg

echo "deb [signed-by=/usr/share/keyrings/jellyfin.gpg] https://repo.jellyfin.org/debian bookworm main" \
  > /etc/apt/sources.list.d/jellyfin.list

apt-get update -q
apt-get install -y jellyfin
systemctl enable --now jellyfin

echo "--- Making /tank/media world-readable for unprivileged LXC ---"
# Note: run this on the Proxmox host (evilbot), not in the container:
#   ssh root@192.168.1.145 "chmod -R o+rX /tank/media"

echo ""
echo "Jellyfin installed and running."
echo "Web UI: http://$JELLYFIN_IP:8096"
echo ""
echo "IMPORTANT: Run on evilbot to allow media access:"
echo "  ssh root@192.168.1.145 \"chmod -R o+rX /tank/media\""
EOF
