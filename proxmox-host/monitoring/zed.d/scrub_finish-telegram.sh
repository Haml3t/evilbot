#!/bin/sh
# ZED zedlet: Telegram alert when a scrub finishes (flags errors if any).
[ -f "${ZED_ZEDLET_DIR}/zed.rc" ] && . "${ZED_ZEDLET_DIR}/zed.rc"
. "${ZED_ZEDLET_DIR}/zed-functions.sh"

[ -n "${ZEVENT_POOL}" ] || exit 0
NOTIFY=/usr/local/bin/notify-telegram.sh
[ -x "$NOTIFY" ] || exit 0

status="$(zpool status "${ZEVENT_POOL}" 2>/dev/null)"
if echo "$status" | grep -qiE "with [1-9][0-9]* errors|DEGRADED|FAULTED|UNAVAIL"; then
  icon="⚠️"
else
  icon="✅"
fi
msg="$(printf '%s ZFS scrub finished — pool "%s".\n\n%s' "$icon" "${ZEVENT_POOL}" "$status")"

"$NOTIFY" "$msg"
