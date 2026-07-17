#!/bin/sh
# ZED zedlet: Telegram alert when a vdev enters a bad state (drive drop / pool degrade).
# Runs alongside the stock statechange-notify.sh (email); does not replace it.
[ -f "${ZED_ZEDLET_DIR}/zed.rc" ] && . "${ZED_ZEDLET_DIR}/zed.rc"
. "${ZED_ZEDLET_DIR}/zed-functions.sh"

[ -n "${ZEVENT_POOL}" ] || exit 0
[ -n "${ZEVENT_VDEV_STATE_STR}" ] || exit 0

# Only alert on failure states, not recovery/ONLINE transitions.
case "${ZEVENT_VDEV_STATE_STR}" in
  FAULTED|DEGRADED|UNAVAIL|REMOVED) ;;
  *) exit 0 ;;
esac

NOTIFY=/usr/local/bin/notify-telegram.sh
[ -x "$NOTIFY" ] || exit 0

# Throttle flapping devices (ZED_NOTIFY_INTERVAL_SECS, default 1h).
zed_rate_limit "telegram-statechange-${ZEVENT_POOL}-${ZEVENT_VDEV_PATH:-x}" || exit 3

vdev="${ZEVENT_VDEV_PATH:-${ZEVENT_VDEV_GUID:-unknown device}}"
msg="$(printf '⚠️ ZFS ALERT — pool "%s"\nDevice %s is now %s.\n\n%s' \
  "${ZEVENT_POOL}" "${vdev}" "${ZEVENT_VDEV_STATE_STR}" "$(zpool status -x 2>/dev/null)")"

"$NOTIFY" "$msg"
