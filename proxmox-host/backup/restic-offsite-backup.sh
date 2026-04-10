#!/usr/bin/env bash
# restic-offsite-backup.sh — incremental encrypted off-site backup to Backblaze B2
#
# What it backs up:
#   /tank/backups/vzdump/dump/   — Proxmox VM/LXC backup archives
#   /tank/backups/host-config/   — nightly pve-config tarballs
#
# What it does NOT back up:
#   /tank/media/                 — too large (~TBs); reproduced from sources
#   /tank/incomplete/            — ephemeral, not worth offloading
#
# Prereqs on evilbot:
#   apt-get install -y restic
#   /root/.secrets/restic-b2.env must exist (see .env.example)
#   restic repo initialized: restic -r b2:<bucket>:<path> init
#
# Cron: /etc/cron.d/restic-offsite
#   0 4 * * * root /usr/local/bin/restic-offsite-backup.sh >> /var/log/restic-offsite.log 2>&1
set -euo pipefail

ENV_FILE="/root/.secrets/restic-b2.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found — cannot load B2 credentials" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

: "${B2_ACCOUNT_ID:?B2_ACCOUNT_ID not set in $ENV_FILE}"
: "${B2_ACCOUNT_KEY:?B2_ACCOUNT_KEY not set in $ENV_FILE}"
: "${RESTIC_PASSWORD:?RESTIC_PASSWORD not set in $ENV_FILE}"
: "${B2_BUCKET:?B2_BUCKET not set in $ENV_FILE}"
: "${B2_PATH:=evilbot}"

export B2_ACCOUNT_ID B2_ACCOUNT_KEY RESTIC_PASSWORD
REPO="b2:${B2_BUCKET}:${B2_PATH}"

log() { echo "[$(date -Iseconds)] $*"; }

log "==> Starting restic off-site backup to $REPO"

# Paths to back up
BACKUP_PATHS=(
  /tank/backups/vzdump/dump
  /tank/backups/host-config
)

# Verify paths exist before starting
for p in "${BACKUP_PATHS[@]}"; do
  if [[ ! -d "$p" ]]; then
    log "WARNING: $p does not exist, skipping"
  fi
done

# Run backup — only include paths that exist
EXISTING_PATHS=()
for p in "${BACKUP_PATHS[@]}"; do
  [[ -d "$p" ]] && EXISTING_PATHS+=("$p")
done

if [[ ${#EXISTING_PATHS[@]} -eq 0 ]]; then
  log "ERROR: No backup paths exist, aborting"
  exit 1
fi

restic -r "$REPO" backup \
  --verbose \
  --tag "evilbot" \
  --tag "automated" \
  "${EXISTING_PATHS[@]}"

log "==> Backup complete. Running retention policy..."

# Retention: keep 7 daily, 4 weekly, 3 monthly snapshots
restic -r "$REPO" forget \
  --keep-daily 7 \
  --keep-weekly 4 \
  --keep-monthly 3 \
  --prune \
  --verbose

log "==> Pruning complete."

# Weekly integrity check — run on Mondays (or if forced with --check)
if [[ "${1:-}" == "--check" ]] || [[ "$(date +%u)" == "1" ]]; then
  log "==> Running repo integrity check..."
  restic -r "$REPO" check
  log "==> Check passed."
fi

log "==> Done."
