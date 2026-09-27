#!/bin/bash
# install-hermes-grant.sh — install time-boxed sudo grants for the `hermes` user.
#
# Model "T2": the operator (not the agent) opens a sudo window from an SSH client:
#     ssh <host> sudo hermes-grant 30        # broad sudo for 30 minutes
#     ssh <host> sudo hermes-revoke          # close it early
#     ssh <host> sudo hermes-grant status    # is a window open, and until when
#
# The grant is a separate file, /etc/sudoers.d/hermes-temp, so any standing
# allowlist in /etc/sudoers.d/hermes is untouched. Every command run during the
# window is logged (logfile + full I/O log), matching fleet/grant-hermes-sudo.sh.
# Expiry is a transient systemd timer, so it survives the operator's SSH
# session ending; a boot-time cleanup covers a reboot mid-window.
#
# The hermes user itself can never run hermes-grant: it needs root, and the
# grant tools are root-owned 0700.
#
# Usage (as root on the target):   bash install-hermes-grant.sh
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
id hermes >/dev/null 2>&1 || { echo "user 'hermes' does not exist on $(hostname)" >&2; exit 1; }
command -v visudo >/dev/null || { echo "sudo not installed" >&2; exit 1; }

install -d -m 700 /var/log/sudo-io

cat > /usr/local/sbin/hermes-grant <<'EOF'
#!/bin/bash
# hermes-grant <minutes>|status — open a time-boxed broad sudo window for `hermes`.
set -euo pipefail
F=/etc/sudoers.d/hermes-temp
UNIT=hermes-grant-expire
[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
if [ "${1:-}" = status ]; then
  if [ -f "$F" ]; then
    echo "OPEN: $(grep -m1 '^# expires' "$F" | sed 's/^# //')"
  else
    echo "closed"
  fi
  exit 0
fi
M="${1:-}"
[[ "$M" =~ ^[0-9]+$ ]] && [ "$M" -ge 1 ] && [ "$M" -le 240 ] \
  || { echo "usage: hermes-grant <minutes 1-240> | status" >&2; exit 2; }
EXP=$(date -u -d "+$M min" '+%Y-%m-%dT%H:%M:%SZ')
TMP=$(mktemp)
cat > "$TMP" <<SUDO
# expires $EXP (granted by ${SUDO_USER:-root} for $M min)
Defaults:hermes !requiretty
Defaults:hermes logfile=/var/log/sudo-hermes.log
Defaults:hermes log_input, log_output
Defaults:hermes iolog_dir=/var/log/sudo-io/%{user}
Defaults:hermes iolog_file=%{seq}
hermes ALL=(ALL:ALL) NOPASSWD: ALL
SUDO
visudo -cf "$TMP" >/dev/null || { visudo -cf "$TMP"; rm -f "$TMP"; exit 1; }
install -m 440 -o root -g root "$TMP" "$F"; rm -f "$TMP"
systemctl stop "$UNIT.timer" "$UNIT.service" 2>/dev/null || true
systemctl reset-failed "$UNIT.timer" "$UNIT.service" 2>/dev/null || true
systemd-run --quiet --unit="$UNIT" --on-active="${M}m" --timer-property=AccuracySec=10s \
  /usr/local/sbin/hermes-revoke --quiet
logger -t hermes-grant "OPEN for $M min until $EXP by ${SUDO_USER:-root}"
echo "hermes: broad sudo OPEN on $(hostname) until $EXP ($M min). Revoke early: sudo hermes-revoke"
EOF

cat > /usr/local/sbin/hermes-revoke <<'EOF'
#!/bin/bash
# hermes-revoke — close the time-boxed sudo window now.
[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
rm -f /etc/sudoers.d/hermes-temp
[ "${1:-}" = --quiet ] || systemctl stop hermes-grant-expire.timer 2>/dev/null || true
logger -t hermes-grant "CLOSED on $(hostname)"
[ "${1:-}" = --quiet ] || echo "hermes: sudo window CLOSED on $(hostname)"
EOF

chmod 700 /usr/local/sbin/hermes-grant /usr/local/sbin/hermes-revoke
chown root:root /usr/local/sbin/hermes-grant /usr/local/sbin/hermes-revoke

# Reboot mid-window: never come back up with the grant still in place.
cat > /etc/systemd/system/hermes-grant-boot-cleanup.service <<'EOF'
[Unit]
Description=Remove any leftover hermes time-boxed sudo grant at boot
[Service]
Type=oneshot
ExecStart=/bin/rm -f /etc/sudoers.d/hermes-temp
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --quiet hermes-grant-boot-cleanup.service

rm -f /etc/sudoers.d/hermes-temp
echo "installed on $(hostname): hermes-grant, hermes-revoke, boot cleanup"
