#!/usr/bin/env bash
# heartbeat-push.sh (runs on evilbot) — tap the opsbot watchdog so it knows evilbot is alive.
# opsbot's forced-command records the timestamp. If opsbot is unreachable, alert once (the
# off-host dead-man's switch is then blind), and clear on recovery.
set -uo pipefail
NOTIFY=/usr/local/bin/notify-telegram.sh
KEY=/root/.ssh/id_ed25519_hbopsbot
OPSBOT=root@192.168.0.224
FLAG=/run/heartbeat-push.failed

ok=""
for a in 1 2 3; do
  if ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=accept-new "$OPSBOT" true 2>/dev/null; then
    ok=1; break
  fi
  sleep 5
done

if [ -n "$ok" ]; then
  if [ -f "$FLAG" ]; then
    [ -x "$NOTIFY" ] && "$NOTIFY" "✅ opsbot watchdog reachable again — heartbeat pushes resumed."
    rm -f "$FLAG"
  fi
  exit 0
fi

if [ ! -f "$FLAG" ]; then
  [ -x "$NOTIFY" ] && "$NOTIFY" "⚠️ evilbot cannot reach the opsbot watchdog (heartbeat push failing). The off-host dead-man's switch is BLIND until opsbot is back."
  touch "$FLAG"
fi
exit 1
