#!/usr/bin/env bash
# pve-config-backup.sh — Tier A: nightly Proxmox HOST CONFIG backup (small, fast, granular)
# Deploy to:  /usr/local/bin/pve-config-backup.sh on evilbot
# Cron:       /etc/cron.d/pve-config-backup — runs daily at 01:30
#
# Produces one compressed tarball per day in /tank/backups/host-config/ containing the
# irreplaceable host configuration plus a metadata manifest (package list, disk/LVM
# layout, pveversion) needed to rebuild the host. 30-day local retention.
#
# SUPERSEDES the old /usr/local/bin/backup-proxmox-config.sh, which wrote to /mnt/tank
# (a plain dir on the ROOT disk, not the pool). That job has been removed.
set -euo pipefail

DEST=/tank/backups/host-config
DATE=$(date +%F)
mkdir -p "$DEST"

# --- stage a metadata manifest (always current — drives bare-metal rebuild) ---
META=$(mktemp -d)
trap 'rm -rf "$META"' EXIT
{
  echo "# evilbot host backup manifest — $(date -Iseconds)"
  echo "## pveversion -v"; pveversion -v 2>/dev/null || true
} > "$META/MANIFEST.txt"
dpkg --get-selections > "$META/dpkg-selections.txt" 2>/dev/null || true
{ echo '### lsblk';   lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT;
  echo '### pvs';     pvs;  echo '### vgs'; vgs; echo '### lvs'; lvs;
  echo '### blkid';   blkid;
  echo '### df -h';   df -h;
  echo '### zpool';   zpool status; echo '### zfs list'; zfs list -t all;
  echo '### ip addr'; ip -o addr; echo '### ip route'; ip route;
} > "$META/disk-network-layout.txt" 2>/dev/null || true

# --- config paths (superset of old pve-config + legacy backup-proxmox-config) ---
PATHS=(
  /etc/pve
  /etc/network/interfaces
  /etc/hosts /etc/hostname /etc/resolv.conf
  /etc/fstab
  /etc/ssh
  /root/.ssh
  /etc/cron.d /var/spool/cron
  /etc/apt/sources.list /etc/apt/sources.list.d
  /etc/sysctl.conf /etc/sysctl.d
  /etc/modprobe.d
  /etc/vzdump.conf
  /usr/local/bin
)
EXISTING=(); for p in "${PATHS[@]}"; do [[ -e "$p" ]] && EXISTING+=("$p"); done

tar czf "${DEST}/pve-config-${DATE}.tar.gz" \
  -C "$META" MANIFEST.txt dpkg-selections.txt disk-network-layout.txt \
  "${EXISTING[@]}" 2>/dev/null

chmod 600 "${DEST}/pve-config-${DATE}.tar.gz"   # contains private keys

# 30-day local retention
find "$DEST" -name 'pve-config-*.tar.gz' -mtime +30 -delete

echo "$(date -Iseconds): config backed up -> ${DEST}/pve-config-${DATE}.tar.gz ($(du -h "${DEST}/pve-config-${DATE}.tar.gz" | cut -f1))"
