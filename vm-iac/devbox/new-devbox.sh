#!/usr/bin/env bash
# new-devbox.sh — spin up a fresh work devbox in one command.
# Usage: ./new-devbox.sh [hostname]
#
# With no arguments: auto-picks the next available VMID and names
# the container devbox-<vmid>.
#
# To destroy a devbox later:
#   ./destroy-devbox.sh <vmid>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVILBOT="root@192.168.1.145"
SECRETS="/root/.secrets/proxmox-tokens.env"

# ── Load Proxmox token ────────────────────────────────────────────────────────
if [[ ! -f "$SECRETS" ]]; then
  echo "ERROR: $SECRETS not found. Cannot authenticate to Proxmox."
  exit 1
fi
# shellcheck source=/dev/null
source "$SECRETS"

# ── Auto-pick next available VMID >= 301 ─────────────────────────────────────
echo "==> Finding next available VMID..."
VMID=$(ssh "$EVILBOT" "
  { pvesh get /nodes/evilbot/lxc  --output-format json 2>/dev/null | python3 -c 'import sys,json; [print(v[\"vmid\"]) for v in json.load(sys.stdin)]';
    pvesh get /nodes/evilbot/qemu --output-format json 2>/dev/null | python3 -c 'import sys,json; [print(v[\"vmid\"]) for v in json.load(sys.stdin)]'; } \
  | sort -n \
  | awk 'BEGIN{n=301} \$1==n{n++} END{print n}'
")
echo "    VMID: $VMID"

# ── Hostname ──────────────────────────────────────────────────────────────────
HOSTNAME="${1:-devbox-$VMID}"
echo "    Hostname: $HOSTNAME"

# ── SSH public key ────────────────────────────────────────────────────────────
SSH_PUBKEY_FILE="$HOME/.ssh/id_ed25519.pub"
if [[ ! -f "$SSH_PUBKEY_FILE" ]]; then
  echo "ERROR: $SSH_PUBKEY_FILE not found."
  echo "Generate one with: ssh-keygen -t ed25519"
  exit 1
fi
SSH_PUBKEY=$(cat "$SSH_PUBKEY_FILE")

# ── Write a temporary tfvars (deleted after apply) ───────────────────────────
TFVARS="$SCRIPT_DIR/.terraform-$VMID.tfvars"
cat > "$TFVARS" << EOF
proxmox_api_token = "$PROXMOX_TOKEN_LXC"
vm_id             = $VMID
hostname          = "$HOSTNAME"
ssh_public_key    = "$SSH_PUBKEY"
EOF
# Ensure it gets cleaned up even if we error out
trap 'rm -f "$TFVARS"' EXIT

# ── Terraform ─────────────────────────────────────────────────────────────────
cd "$SCRIPT_DIR"

echo "==> Initialising Terraform..."
terraform init -upgrade -input=false -no-color > /dev/null

echo "==> Creating container $VMID ($HOSTNAME)..."
terraform apply \
  -auto-approve \
  -input=false \
  -var-file="$TFVARS" \
  -state="$SCRIPT_DIR/terraform-$VMID.tfstate"

# tfvars deleted here by trap

# ── Provision (inject secrets, install tools, clone repos) ───────────────────
"$SCRIPT_DIR/provision.sh" "$VMID"
