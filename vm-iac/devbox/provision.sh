#!/usr/bin/env bash
# provision.sh — run from claudebot after `terraform apply` to bootstrap a devbox.
# Usage: ./provision.sh <vmid>
#
# What this does:
#   1. Waits for the container to be running
#   2. Injects /root/.secrets/devbox.env from evilbot into the container (never touches disk here)
#   3. Copies repos.txt into the container
#   4. Uploads and runs bootstrap.sh inside the container
#
# Secrets flow: evilbot:/root/.secrets/devbox.env → pct exec → container:/root/.env
# Nothing sensitive passes through claudebot or Terraform state.
set -euo pipefail

VMID="${1:?Usage: $0 <vmid>}"
EVILBOT="root@192.168.1.145"
EVILBOT_SECRETS="/root/.secrets/devbox.env"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── 1. Wait for container to be running ──────────────────────────────────────
echo "==> Waiting for container $VMID to start..."
for i in $(seq 1 30); do
  status=$(ssh "$EVILBOT" "pct status $VMID 2>/dev/null" || echo "unknown")
  if echo "$status" | grep -q "running"; then
    echo "    Container is running."
    break
  fi
  printf "    (%d/30) status: %s — retrying...\n" "$i" "$status"
  sleep 3
done

# Give network a moment to come up
sleep 5

# ── 2. Verify secrets file exists on evilbot ─────────────────────────────────
echo "==> Checking secrets file on evilbot..."
if ! ssh "$EVILBOT" "test -f $EVILBOT_SECRETS"; then
  echo ""
  echo "ERROR: $EVILBOT_SECRETS not found on evilbot."
  echo "Create it from the template:"
  echo "  scp $SCRIPT_DIR/devbox-secrets.env.example root@192.168.1.145:$EVILBOT_SECRETS"
  echo "  ssh root@192.168.1.145 'vi $EVILBOT_SECRETS'"
  exit 1
fi

# ── 3. Inject secrets: evilbot secrets file → container /root/.env ───────────
echo "==> Injecting secrets into container $VMID..."
ssh "$EVILBOT" "cat $EVILBOT_SECRETS | pct exec $VMID -- tee /root/.env > /dev/null"
ssh "$EVILBOT" "pct exec $VMID -- chmod 600 /root/.env"
echo "    /root/.env written (mode 600)"

# ── 4. Copy repos.txt and CLAUDE.md.template into container ──────────────────
echo "==> Copying repos.txt into container..."
REPOS_B64=$(base64 < "$SCRIPT_DIR/repos.txt")
ssh "$EVILBOT" "echo '$REPOS_B64' | base64 -d | pct exec $VMID -- tee /root/repos.txt > /dev/null"
echo "    /root/repos.txt written"

echo "==> Copying CLAUDE.md.template into container..."
CLAUDE_B64=$(base64 < "$SCRIPT_DIR/CLAUDE.md.template")
ssh "$EVILBOT" "echo '$CLAUDE_B64' | base64 -d | pct exec $VMID -- tee /root/CLAUDE.md.template > /dev/null"
echo "    /root/CLAUDE.md.template written"

# ── 5. Upload bootstrap.sh into container ────────────────────────────────────
echo "==> Uploading bootstrap.sh..."
BOOTSTRAP_B64=$(base64 < "$SCRIPT_DIR/bootstrap.sh")
ssh "$EVILBOT" "echo '$BOOTSTRAP_B64' | base64 -d | pct exec $VMID -- tee /root/bootstrap.sh > /dev/null"
ssh "$EVILBOT" "pct exec $VMID -- chmod 755 /root/bootstrap.sh"
echo "    /root/bootstrap.sh written"

# ── 6. Run bootstrap inside the container ────────────────────────────────────
echo "==> Running bootstrap.sh inside container $VMID (this takes a few minutes)..."
echo "    Tail log: ssh -J $EVILBOT root@<ip> 'tail -f /root/bootstrap.log'"
echo ""
ssh "$EVILBOT" "pct exec $VMID -- bash /root/bootstrap.sh"

# ── 7. Discover container IP ─────────────────────────────────────────────────
echo ""
echo "==> Getting container IP..."
CONTAINER_IP=$(ssh "$EVILBOT" \
  "pct exec $VMID -- ip -4 addr show eth0 2>/dev/null" \
  | grep inet | awk '{print $2}' | cut -d/ -f1 || echo "unknown")

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  devbox $VMID is ready!                                     "
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  IP:      $CONTAINER_IP"
echo "║  SSH:     ssh -J root@192.168.1.145 root@$CONTAINER_IP"
echo "║  Repos:   ~/work/"
echo "║  Claude:  first SSH will prompt for OAuth login (one-time)"
echo "╚══════════════════════════════════════════════════════════════╝"
