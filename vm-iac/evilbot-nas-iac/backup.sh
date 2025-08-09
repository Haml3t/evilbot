#!/usr/bin/env bash

# Auto-load local .env if present
if [ -f ".env" ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

set -euo pipefail
cd "$(dirname "$0")"  # ensure we’re in evilbot-nas-iac/

# Activate Ansible venv (optional)
if [ -f ".venv/bin/activate" ]; then
  # shellcheck disable=SC1091
  source .venv/bin/activate
fi

pushd ansible >/dev/null

# Run your existing backup playbook (prompts for sudo if needed)
ANSIBLE_STDOUT_CALLBACK=yaml \
ansible-playbook -i hosts playbooks/backup.yaml --ask-become-pass

# Timestamp and archive the current backup tree
ts="$(date +%Y%m%d_%H%M%S)"
mkdir -p backups/_archives
tar -czf "backups/_archives/evilbot-nas_${ts}.tar.gz" -C backups evilbot-nas

echo
echo "✅ Backup complete."
echo "   Archive: ansible/backups/_archives/evilbot-nas_${ts}.tar.gz"
echo "   (Contains the files produced by the backup playbook.)"

popd >/dev/null
