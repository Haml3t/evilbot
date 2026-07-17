#!/usr/bin/env bash
# host-health-check.sh — evilbot host-level checks: critical guests running + failed units.
# Alerts to Telegram only on problems. Exit 0 = ran OK (even if it alerted); 2 = couldn't run.
set -uo pipefail

NOTIFY=/usr/local/bin/notify-telegram.sh

# vmids that must always be running (NAS, telegram, jellyfin, inferbot, opsbot).
EXPECTED_GUESTS="100 200 400 500 600"
# Failed systemd units to ignore (space-separated), e.g. "fail2ban.service".
IGNORE_FAILED_UNITS=""

command -v pct >/dev/null 2>&1 || { echo "FATAL: pct not found" >&2; exit 2; }

problems=""

for id in $EXPECTED_GUESTS; do
  st="$(pct status "$id" 2>/dev/null || qm status "$id" 2>/dev/null || echo 'status: unknown')"
  echo "$st" | grep -q "running" || problems="${problems}Guest ${id} is NOT running (${st}).
"
done

failed="$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}')"
for u in $failed; do
  [ -n "$u" ] || continue
  case " $IGNORE_FAILED_UNITS " in *" $u "*) continue ;; esac
  problems="${problems}systemd unit FAILED: ${u}
"
done

if [ -n "$problems" ]; then
  [ -x "$NOTIFY" ] && "$NOTIFY" "$(printf '🖧 evilbot host check found issues:\n\n%s' "$problems")"
fi
exit 0
