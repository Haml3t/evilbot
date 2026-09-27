#!/bin/bash
# satellite-bootstrap.sh — the ONE command the operator runs on a personal Ubuntu
# machine to hand it to Hermes. Everything after this is done by Hermes via Ansible,
# inside the time-boxed sudo window this script opens at the end.
#
# What it does (idempotent):
#   1. creates user `hermes`: password locked, pubkey-only, hermesbot's key only
#   2. makes sure sshd runs and admits `hermes` (AllowUsers / ufw, if in use)
#   3. installs hermes-grant / hermes-revoke (fleet/install-hermes-grant.sh)
#   4. opens a sudo window (default 120 min) so Hermes can run the playbook
#
# It does NOT install backups, the standing allowlist, or the Hermes agent — the
# playbook does, and the window closes by itself.
#
# Usage:  curl -fsSL <raw-url>/fleet/satellite-bootstrap.sh | sudo bash -s -- [minutes]
set -euo pipefail
MIN="${1:-120}"
REF="${HERMES_REF:-main}"
RAW="https://raw.githubusercontent.com/Haml3t/evilbot/$REF/fleet"
PUBKEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMmhaYs34rDwMm/rcxqLI2/3HFcv9bjo9OJ0H/Mw9qzf hermesbot-fleet-ro'

[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
. /etc/os-release; [ "$ID" = ubuntu ] || { echo "Ubuntu only (got $ID)" >&2; exit 1; }

# 1. user
if ! id hermes >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash --comment "Hermes agent" hermes
fi
passwd -l hermes >/dev/null
install -d -m 700 -o hermes -g hermes /home/hermes/.ssh
printf '%s\n' "$PUBKEY" > /home/hermes/.ssh/authorized_keys
chown hermes:hermes /home/hermes/.ssh/authorized_keys; chmod 600 /home/hermes/.ssh/authorized_keys

# 2. sshd
command -v sshd >/dev/null || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server; }
systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now ssh.socket >/dev/null 2>&1 || true
if sshd -T 2>/dev/null | grep -qi '^allowusers'; then
  if ! sshd -T | grep -i '^allowusers' | grep -qw hermes; then
    echo "AllowUsers hermes" > /etc/ssh/sshd_config.d/60-hermes.conf
    sshd -t && systemctl reload ssh
  fi
fi
if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
  ufw allow from 192.168.0.225 to any port 22 proto tcp comment hermesbot >/dev/null
  ip link show tailscale0 >/dev/null 2>&1 && ufw allow in on tailscale0 to any port 22 proto tcp comment tailnet-ssh >/dev/null
fi

# 3. grant tooling
command -v visudo >/dev/null || { apt-get update -qq && apt-get install -y -qq sudo; }
curl -fsSL "$RAW/install-hermes-grant.sh" | bash

# 4. open the window for the playbook run
/usr/local/sbin/hermes-grant "$MIN"
echo
echo "Done on $(hostname). Tell Hermes: 'bootstrapped $(hostname)'."
echo "Tailscale: $(tailscale ip -4 2>/dev/null || echo 'not on tailnet')   LAN: $(hostname -I | awk '{print $1}')"
