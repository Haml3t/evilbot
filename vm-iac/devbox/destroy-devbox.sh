#!/usr/bin/env bash
# destroy-devbox.sh — tear down a devbox created by new-devbox.sh.
# Usage: ./destroy-devbox.sh <vmid>
set -euo pipefail

VMID="${1:?Usage: $0 <vmid>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVILBOT="root@192.168.1.145"
SECRETS="/root/.secrets/proxmox-tokens.env"
STATE="$SCRIPT_DIR/terraform-$VMID.tfstate"

# ── Sanity checks ─────────────────────────────────────────────────────────────
if [[ ! -f "$STATE" ]]; then
  echo "ERROR: No state file found at $STATE"
  echo "If the container still exists, destroy it manually:"
  echo "  ssh $EVILBOT 'pct stop $VMID && pct destroy $VMID'"
  exit 1
fi

source "$SECRETS"

TFVARS="$SCRIPT_DIR/.terraform-$VMID.tfvars"
cat > "$TFVARS" << EOF
proxmox_api_token = "$PROXMOX_TOKEN_LXC"
vm_id             = $VMID
hostname          = "devbox-$VMID"
ssh_public_key    = "$(cat "$HOME/.ssh/id_ed25519.pub")"
EOF
trap 'rm -f "$TFVARS"' EXIT

# ── Confirm ───────────────────────────────────────────────────────────────────
echo "This will permanently destroy devbox $VMID. All data inside will be lost."
read -r -p "Type the VMID to confirm: " CONFIRM
if [[ "$CONFIRM" != "$VMID" ]]; then
  echo "Aborted."
  exit 1
fi

# ── Destroy ───────────────────────────────────────────────────────────────────
cd "$SCRIPT_DIR"
terraform destroy \
  -auto-approve \
  -input=false \
  -var-file="$TFVARS" \
  -state="$STATE"

rm -f "$STATE" "$STATE.backup"
echo "==> devbox $VMID destroyed and state cleaned up."
