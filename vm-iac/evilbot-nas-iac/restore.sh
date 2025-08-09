#!/usr/bin/env bash

# Auto-load local .env if present
if [ -f ".env" ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

set -euo pipefail
cd "$(dirname "$0")"  # run from evilbot-nas-iac/

# Usage:
#   ./restore.sh                               -> terraform apply, restore from latest
#   ./restore.sh --no-tf                       -> skip terraform
#   ./restore.sh --archive ansible/backups/_archives/evilbot-nas_20250807_120301.tar.gz
#   ./restore.sh --snapshot 20250807_120301    -> picks that timestamped archive
#   ./restore.sh --restore-host-keys           -> also restore /etc/ssh/ssh_host_*

DO_TF=1
ARCHIVE_ARG=""
SNAPSHOT_ARG=""
RESTORE_HOST_KEYS="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-tf) DO_TF=0; shift ;;
    --archive) ARCHIVE_ARG="$2"; shift 2 ;;
    --snapshot) SNAPSHOT_ARG="$2"; shift 2 ;;
    --restore-host-keys) RESTORE_HOST_KEYS="true"; shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ "$DO_TF" -eq 1 ]]; then
  echo "▶ Terraform apply (provision/ensure VM matches code)"
  pushd terraform >/dev/null
  terraform init -input=false
  terraform validate
  terraform apply -auto-approve
  popd >/dev/null
fi

# Activate Ansible venv if present
if [ -f ".venv/bin/activate" ]; then
  # shellcheck disable=SC1091
  source .venv/bin/activate
fi

pushd ansible >/dev/null

# Choose archive
if [[ -n "$ARCHIVE_ARG" ]]; then
  ARCHIVE="$ARCHIVE_ARG"
elif [[ -n "$SNAPSHOT_ARG" ]]; then
  ARCHIVE="backups/_archives/evilbot-nas_${SNAPSHOT_ARG}.tar.gz"
else
  ARCHIVE="$(ls -1t backups/_archives/evilbot-nas_*.tar.gz | head -n 1)"
fi

if [[ ! -f "$ARCHIVE" ]]; then
  echo "❌ Archive not found: $ARCHIVE"
  echo "   Use --snapshot <YYYYmmdd_HHMMSS> or --archive <path>"
  exit 1
fi

echo "Using archive: $ARCHIVE"

RESTORE_TMP="$(mktemp -d -t evilbot-restore-XXXXXX)"
tar -xzf "$ARCHIVE" -C "$RESTORE_TMP"

RESTORE_SRC="$RESTORE_TMP/evilbot-nas"
if [[ ! -d "$RESTORE_SRC" ]]; then
  echo "❌ Expected directory not found: $RESTORE_SRC"
  exit 1
fi

ANSIBLE_STDOUT_CALLBACK=yaml \
ansible-playbook -i hosts playbooks/restore.yaml \
  --ask-become-pass \
  -e "restore_src=$RESTORE_SRC" \
  -e "restore_host_keys=$RESTORE_HOST_KEYS"

echo
echo "✅ Restore complete."
echo "   Temporary extracted files in: $RESTORE_TMP"
echo "   (Remove it when satisfied.)"
popd >/dev/null
