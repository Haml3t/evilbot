#!/usr/bin/env bash
# restic-offsite-backup.sh — incremental encrypted off-site backup to Backblaze B2
#
# What it backs up:
#   /tank/backups/vzdump/dump/   — Proxmox VM/LXC backup archives
#   /tank/backups/host-config/   — nightly pve-config tarballs (Tier A)
#   /tank/backups/host-system/   — weekly OS-core system tars (Tier B1)
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

log() { echo "[$(date -Iseconds)] $*"; }

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found — cannot load B2 credentials" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

: "${B2_PATH:=evilbot}"

# Graceful pause: until real B2 credentials are filled in, skip cleanly (exit 0) so the
# nightly cron job does not fail-mail. Placeholder values come from restic-b2.env.example.
if [[ -z "${B2_ACCOUNT_ID:-}" || "${B2_ACCOUNT_ID}" == your-* \
   || -z "${B2_ACCOUNT_KEY:-}" || "${B2_ACCOUNT_KEY}" == your-* \
   || -z "${B2_BUCKET:-}"     || "${B2_BUCKET}" == your-* \
   || -z "${RESTIC_PASSWORD:-}" ]]; then
  log "PAUSED: B2 credentials not yet configured in $ENV_FILE — skipping cloud backup (exit 0)"
  exit 0
fi

export B2_ACCOUNT_ID B2_ACCOUNT_KEY RESTIC_PASSWORD
REPO="b2:${B2_BUCKET}:${B2_PATH}"

log "==> Starting restic off-site backup to $REPO"

# Initialize the repo on first run (idempotent — skips if already initialized).
if ! restic -r "$REPO" cat config >/dev/null 2>&1; then
  log "==> Repo not initialized — running 'restic init'"
  restic -r "$REPO" init
fi

# Paths to back up
# NOTE (2026-08-29): vzdump guest images are deliberately EXCLUDED from the cloud
# copy. They are ~259G (vs ~155G for host-system + 411M for host-config), already
# covered by the nightly off-host rsync to the desktop, and including them turned
# the initial seed into a multi-day job that was never completed — leaving the B2
# repo empty for 6 weeks. The cloud tier's job is to make the HOST rebuildable
# off-pool and immutably; guest images stay on the off-host leg.
BACKUP_PATHS=(
  /tank/backups/host-config
  /tank/backups/host-system
  # Local-only secrets vault (bare git repo, mode 700 root). Added 2026-08-30.
  # This is the ONLY offsite copy it gets — it is deliberately not on GitHub, and
  # /tank has no redundancy against the known non-ECC RAM fault. restic encrypts
  # client-side, so shipping it to B2 does not expose the credentials it holds.
  /tank/vault
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
