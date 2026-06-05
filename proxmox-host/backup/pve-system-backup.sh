#!/usr/bin/env bash
# pve-system-backup.sh — Tier B1: weekly OS-CORE system tar (bare-metal rebuild kit)
# Deploy to:  /usr/local/bin/pve-system-backup.sh on evilbot
# Cron:       /etc/cron.d/pve-system-backup — runs weekly, Sunday 03:30
#
# Captures the entire installed root filesystem EXCEPT regenerable bulk data
# (Docker images, AI models, templates, logs, caches). Restore path:
#   reinstall Proxmox base -> untar this over / -> reboot -> re-pull docker/models.
#
# Excluded (internet-regenerable, see docs/proxmox-host-backup-recovery.md):
#   /var/lib/docker  (~24G)   /opt/ai (~12G)   /var/lib/vz (templates)
#   logs, caches, tmp, apt lists, other mounts (/tank via --one-file-system)
set -euo pipefail

DEST=/tank/backups/host-system
DATE=$(date +%F)
mkdir -p "$DEST"
OUT="${DEST}/pve-system-${DATE}.tar.zst"

# Compressor: zstd multithreaded if available, else gzip
if command -v zstd >/dev/null 2>&1; then
  COMP=(-I 'zstd -3 -T0'); OUT="${DEST}/pve-system-${DATE}.tar.zst"
else
  COMP=(-z);               OUT="${DEST}/pve-system-${DATE}.tar.gz"
fi

echo "$(date -Iseconds): starting system tar -> $OUT"

# --one-file-system keeps tar on the root fs (auto-skips /tank, /proc, /sys, /dev, /run,
# /boot/efi). Explicit excludes drop regenerable bulk that lives ON the root fs.
tar "${COMP[@]}" \
  --one-file-system \
  --exclude=/var/lib/docker \
  --exclude=/opt/ai \
  --exclude=/var/lib/vz \
  --exclude=/var/log \
  --exclude=/var/cache \
  --exclude=/var/tmp \
  --exclude=/tmp \
  --exclude=/root/.cache \
  --exclude=/var/lib/apt/lists \
  --exclude=/mnt \
  --exclude=/media \
  --exclude=/swap.img \
  --exclude=/var/swap \
  -cpf "$OUT" / 2>/dev/null || true   # tar warns on files changing during read; non-fatal

chmod 600 "$OUT"

# Retention: keep ~6 weeks of weekly images
find "$DEST" -name 'pve-system-*.tar.*' -mtime +45 -delete

echo "$(date -Iseconds): system backup complete -> $OUT ($(du -h "$OUT" | cut -f1))"
