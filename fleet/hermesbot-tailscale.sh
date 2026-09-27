#!/bin/bash
# hermesbot-tailscale.sh — join hermesbot (CT 700) to the tailnet as tag:hermes.
#
# Userspace networking: no /dev/net/tun, no LXC config change, NO container reboot
# (a reboot would kill any running Hermes session). Outbound SSH to tailnet peers
# goes through `ProxyCommand tailscale nc %h %p`; `--operator=hermes` lets the
# unprivileged hermes user use that without root.
#
# Needs a pre-authorised, tagged auth key (admin console -> Settings -> Keys ->
# Generate auth key: Reusable=off, Ephemeral=off, Tags=tag:hermes). Prompted for,
# never echoed, never written to disk.
#
# Run as root on the evilbot host:   bash hermesbot-tailscale.sh
set -euo pipefail
CT=700
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
command -v pct >/dev/null || { echo "run on the Proxmox host" >&2; exit 1; }
[ "$(pct status $CT)" = "status: running" ] || { echo "CT $CT not running" >&2; exit 1; }

if pct exec $CT -- tailscale status >/dev/null 2>&1; then
  echo "hermesbot already on the tailnet: $(pct exec $CT -- tailscale ip -4)"; exit 0
fi

read -rsp "tag:hermes auth key (tskey-auth-...): " KEY; echo
[[ "$KEY" == tskey-auth-* ]] || { echo "that does not look like an auth key" >&2; exit 1; }

pct exec $CT -- bash -c 'command -v tailscale >/dev/null || curl -fsSL https://tailscale.com/install.sh | sh'
pct exec $CT -- bash -c '
  sed -i "s|^FLAGS=.*|FLAGS=\"--tun=userspace-networking\"|" /etc/default/tailscaled
  grep -q userspace-networking /etc/default/tailscaled || echo "FLAGS=\"--tun=userspace-networking\"" >> /etc/default/tailscaled
  systemctl enable tailscaled >/dev/null 2>&1; systemctl restart tailscaled'
sleep 2
pct exec $CT -- tailscale up --auth-key="$KEY" \
  --hostname=hermesbot --operator=hermes --accept-dns=false
unset KEY
echo "hermesbot tailnet IP: $(pct exec $CT -- tailscale ip -4)"
pct exec $CT -- tailscale status --self --peers=false
