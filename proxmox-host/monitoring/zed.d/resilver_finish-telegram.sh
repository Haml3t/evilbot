#!/bin/sh
# ZED zedlet: Telegram alert when a resilver completes (e.g. after a drive replace).
[ -f "${ZED_ZEDLET_DIR}/zed.rc" ] && . "${ZED_ZEDLET_DIR}/zed.rc"
. "${ZED_ZEDLET_DIR}/zed-functions.sh"

[ -n "${ZEVENT_POOL}" ] || exit 0
NOTIFY=/usr/local/bin/notify-telegram.sh
[ -x "$NOTIFY" ] || exit 0

msg="$(printf '✅ ZFS resilver finished — pool "%s".\n\n%s' \
  "${ZEVENT_POOL}" "$(zpool status "${ZEVENT_POOL}" 2>/dev/null)")"

"$NOTIFY" "$msg"
