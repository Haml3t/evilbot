#!/bin/sh
# ZED zedlet: Telegram alert on ZFS data/checksum errors (early corruption signal).
[ -f "${ZED_ZEDLET_DIR}/zed.rc" ] && . "${ZED_ZEDLET_DIR}/zed.rc"
. "${ZED_ZEDLET_DIR}/zed-functions.sh"

[ -n "${ZEVENT_POOL}" ] || exit 0

NOTIFY=/usr/local/bin/notify-telegram.sh
[ -x "$NOTIFY" ] || exit 0

# Data errors can burst; throttle hard (default 1h per pool).
zed_rate_limit "telegram-data-${ZEVENT_POOL}" || exit 3

vdev="${ZEVENT_VDEV_PATH:-a device}"
msg="$(printf '⚠️ ZFS DATA ERROR — pool "%s"\nChecksum/read/write error on %s. Inspect with: zpool status -v %s\n\n%s' \
  "${ZEVENT_POOL}" "${vdev}" "${ZEVENT_POOL}" "$(zpool status -x 2>/dev/null)")"

"$NOTIFY" "$msg"
