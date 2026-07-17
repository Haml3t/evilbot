#!/usr/bin/env bash
# zfs-scrub-guarded.sh — start a scrub ONLY if the pool is ONLINE/healthy.
# Skips (and notifies) while DEGRADED/resilvering so we don't stress an array with no
# redundancy. Once the 10TB is resilvered and the pool is ONLINE, the monthly scrub runs.
set -uo pipefail
POOL="${1:-tank}"
NOTIFY=/usr/local/bin/notify-telegram.sh

health="$(zpool list -H -o health "$POOL" 2>/dev/null || echo UNKNOWN)"
if [ "$health" != "ONLINE" ]; then
  [ -x "$NOTIFY" ] && "$NOTIFY" "⏭️ Monthly scrub of '${POOL}' SKIPPED — pool is ${health} (not ONLINE). Will scrub automatically once healthy/resilvered."
  exit 0
fi

# Don't stack a scrub on top of an in-progress scrub/resilver.
if zpool status "$POOL" 2>/dev/null | grep -qiE "scrub in progress|resilver in progress"; then
  [ -x "$NOTIFY" ] && "$NOTIFY" "⏭️ Monthly scrub of '${POOL}' SKIPPED — a scrub/resilver is already running."
  exit 0
fi

zpool scrub "$POOL"
[ -x "$NOTIFY" ] && "$NOTIFY" "🧹 Monthly scrub of '${POOL}' started. You'll get the result when it finishes."
exit 0
