#!/usr/bin/env bash
# Daily ZFS snapshots of the tank pool with 14-day retention.
# Deploy to: /usr/local/bin/zfs-snapshot-daily.sh on evilbot
# Cron: /etc/cron.d/zfs-daily-snapshot — runs at 01:00
set -euo pipefail

DATE=$(date +%F)
POOL=tank
KEEP_DAYS=14

zfs snapshot -r ${POOL}@daily-${DATE}

CUTOFF=$(date -d "${KEEP_DAYS} days ago" +%F)
zfs list -H -t snapshot -o name | grep '@daily-' | while read snap; do
  SNAP_DATE=${snap##*@daily-}
  if [[ "$SNAP_DATE" < "$CUTOFF" ]]; then
    zfs destroy "$snap" && echo "Pruned: $snap"
  fi
done
