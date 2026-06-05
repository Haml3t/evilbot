#!/usr/bin/env bash
# host-offsite-sync.sh — Item 3: off-host copy of host backups to a separate machine
# Deploy to:  /usr/local/bin/host-offsite-sync.sh on evilbot
# Cron:       /etc/cron.d/host-offsite-sync — runs daily at 04:30 (after config + system jobs)
#
# rsync of the local host-backup dirs to a SECOND PHYSICAL machine (a desktop on the LAN),
# so a dead evilbot boot disk OR a dead tank pool still leaves an on-prem copy.
#
# Offsite target is read from /root/.secrets/offsite-sync.env (gitignored — see
# offsite-sync.env.example). Requires evilbot's root SSH key trusted by OFFSITE_USER:
#   (on the offsite host)  echo '<evilbot /root/.ssh/id_rsa.pub>' >> ~/.ssh/authorized_keys
# Until both are set up this job logs a warning and exits 0 (non-fatal).
set -uo pipefail

# Defaults are placeholders; real values come from the gitignored env file below.
OFFSITE_HOST="<offsite-host>"
OFFSITE_USER="<offsite-user>"
OFFSITE_BASE="/backups/evilbot"
[ -f /root/.secrets/offsite-sync.env ] && source /root/.secrets/offsite-sync.env

SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=8"
log() { echo "[$(date -Iseconds)] $*"; }

if [[ "$OFFSITE_HOST" == "<offsite-host>" ]]; then
  log "PAUSED: offsite target not configured in /root/.secrets/offsite-sync.env — skipping (exit 0)"
  exit 0
fi

# Reachability / auth probe — degrade gracefully if the key is not installed yet.
if ! ssh $SSH_OPTS "${OFFSITE_USER}@${OFFSITE_HOST}" "mkdir -p ${OFFSITE_BASE}/host-config ${OFFSITE_BASE}/host-system" 2>/dev/null; then
  log "WARNING: cannot SSH to ${OFFSITE_USER}@${OFFSITE_HOST} (key not installed yet?) — skipping off-host sync"
  exit 0
fi

log "==> syncing host-config -> offsite"
rsync -a --delete -e "ssh $SSH_OPTS" \
  /tank/backups/host-config/ "${OFFSITE_USER}@${OFFSITE_HOST}:${OFFSITE_BASE}/host-config/"

log "==> syncing host-system -> offsite"
rsync -a --delete -e "ssh $SSH_OPTS" \
  /tank/backups/host-system/ "${OFFSITE_USER}@${OFFSITE_HOST}:${OFFSITE_BASE}/host-system/"

log "==> off-host sync complete"
