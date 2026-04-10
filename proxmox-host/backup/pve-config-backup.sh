#!/usr/bin/env bash
# Nightly backup of Proxmox host config to /tank/backups/host-config/
# Deploy to: /usr/local/bin/pve-config-backup.sh on evilbot
# Cron: /etc/cron.d/pve-config-backup — runs at 01:30
set -euo pipefail

DEST=/tank/backups/host-config
DATE=$(date +%F)
mkdir -p "$DEST"

tar czf "${DEST}/pve-config-${DATE}.tar.gz" \
  /etc/pve \
  /etc/network/interfaces \
  /etc/cron.d \
  /usr/local/bin/zfs-snapshot-daily.sh \
  /usr/local/bin/pve-config-backup.sh \
  2>/dev/null

find "$DEST" -name 'pve-config-*.tar.gz' -mtime +30 -delete
echo "$(date): backed up to ${DEST}/pve-config-${DATE}.tar.gz"
