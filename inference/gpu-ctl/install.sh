#!/usr/bin/env bash
# One-shot install of gpu-ctl on gpu-desktop. Run as root from a repo checkout:
#   sudo bash inference/gpu-ctl/install.sh
# Idempotent: keeps an existing token/config, refreshes the script + unit.
set -euo pipefail
cd "$(dirname "$0")"
install -d -m 755 /opt/gpu-ctl /etc/gpu-ctl
install -m 755 gpu-ctl.py /opt/gpu-ctl/gpu-ctl.py
if [ ! -s /etc/gpu-ctl.env ]; then
  install -m 600 /dev/null /etc/gpu-ctl.env
  printf 'GPU_CTL_TOKEN=%s\n' "$(openssl rand -hex 32)" > /etc/gpu-ctl.env
fi
if [ ! -s /etc/gpu-ctl/config.json ]; then
  # token comes from /etc/gpu-ctl.env (env wins over config), so blank it here
  sed 's/"REPLACE_WITH_openssl_rand_hex_32"/""/' config.example.json > /etc/gpu-ctl/config.json
  chmod 600 /etc/gpu-ctl/config.json
fi
install -m 644 gpu-ctl.service /etc/systemd/system/gpu-ctl.service
systemctl daemon-reload
systemctl enable gpu-ctl
systemctl restart gpu-ctl
# token readable by the hermes account so Hermes can drive /state, /lockout, /unlock
if id hermes >/dev/null 2>&1; then
  install -m 640 -g hermes /etc/gpu-ctl.env /etc/gpu-ctl.hermes-token
fi
sleep 2
curl -s localhost:9840/health && echo
systemctl --no-pager --lines=5 status gpu-ctl
