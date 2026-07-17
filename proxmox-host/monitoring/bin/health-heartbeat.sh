#!/usr/bin/env bash
# Weekly proof-of-life: positive "monitoring is alive" message. Its ABSENCE is the signal.
set -uo pipefail
NOTIFY=/usr/local/bin/notify-telegram.sh
[ -x "$NOTIFY" ] || exit 0

pool="$(zpool list -H -o name,health,size,alloc,free tank 2>/dev/null || echo 'tank: status unavailable')"
ndisks="$(ls /dev/sd? 2>/dev/null | wc -l | tr -d ' ')"
xstat="$(zpool status -x 2>/dev/null)"

"$NOTIFY" "$(printf '💓 Weekly proof-of-life — evilbot storage monitoring is running.\nPool: %s\nData disks seen: %s\n%s\n\n(If this weekly message ever stops arriving, the monitor or the host may be down.)' \
  "$pool" "$ndisks" "$xstat")"
