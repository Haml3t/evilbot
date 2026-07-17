#!/usr/bin/env bash
# notify-telegram.sh — send a message to Telegram via the evilbot bot.
# Usage:  notify-telegram.sh "message text"   (or pipe text on stdin)
# Creds come from /etc/zfs-alert.env (root-only): TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID.
set -uo pipefail

ENV_FILE=/etc/zfs-alert.env
if [ ! -r "$ENV_FILE" ]; then
  logger -t notify-telegram "missing/unreadable $ENV_FILE"
  exit 1
fi
# shellcheck disable=SC1090
. "$ENV_FILE"
: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN unset}" "${TELEGRAM_CHAT_ID:?TELEGRAM_CHAT_ID unset}"

msg="${1:-}"
[ -n "$msg" ] || msg="$(cat)"
[ -n "$msg" ] || exit 0

host="$(hostname -s 2>/dev/null || hostname)"
text="$(printf '🖥️ %s\n%s' "$host" "$msg")"
# Telegram hard-caps a message at 4096 chars.
text="${text:0:4000}"

for attempt in 1 2 3; do
  if curl -fsS --max-time 15 \
      "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=${text}" \
      --data "disable_web_page_preview=true" \
      -o /dev/null; then
    exit 0
  fi
  sleep $((attempt * 3))
done

logger -t notify-telegram "failed to send after 3 attempts: ${msg:0:120}"
exit 1
