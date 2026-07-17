#!/usr/bin/env bash
# heartbeat-watchdog.sh (runs on opsbot) — the off-host dead-man's switch.
# If evilbot hasn't checked in within THRESHOLD, evilbot is down/hung or its monitoring
# has stopped -> alert (once), and send a recovery notice when it checks in again.
set -uo pipefail
NOTIFY=/usr/local/bin/notify-telegram.sh
STATE_DIR=/var/lib/health-watchdog
LAST_FILE="$STATE_DIR/evilbot.last"
ALERT_FLAG="$STATE_DIR/evilbot.alerted"
THRESHOLD=3600   # seconds; evilbot pushes every 15 min, so 1h tolerates ~3 misses.

mkdir -p "$STATE_DIR"
now="$(date +%s)"
last=0
[ -r "$LAST_FILE" ] && last="$(cat "$LAST_FILE" 2>/dev/null || echo 0)"
case "$last" in ''|*[!0-9]*) last=0 ;; esac
age=$(( now - last ))

if [ "$last" -eq 0 ] || [ "$age" -gt "$THRESHOLD" ]; then
  if [ ! -f "$ALERT_FLAG" ]; then
    if [ "$last" -eq 0 ]; then detail="no heartbeat ever recorded"; else detail="last heartbeat ${age}s ago (>$((THRESHOLD/60)) min)"; fi
    [ -x "$NOTIFY" ] && "$NOTIFY" "🚨 DEAD-MAN'S SWITCH TRIPPED — ${detail}. evilbot may be DOWN, hung, or its storage monitoring has stopped. Check the Proxmox host."
    touch "$ALERT_FLAG"
  fi
else
  if [ -f "$ALERT_FLAG" ]; then
    [ -x "$NOTIFY" ] && "$NOTIFY" "✅ RECOVERED — evilbot heartbeat is fresh again (age ${age}s)."
    rm -f "$ALERT_FLAG"
  fi
fi
exit 0
