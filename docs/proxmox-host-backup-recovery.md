# evilbot — Proxmox host backup & recovery

How the host (OS + config) is backed up, and how to recover. Guest VMs/LXCs are covered
separately by the `vzdump` job (02:00 → `/tank/backups/vzdump`).

## What runs (all on evilbot, via `/etc/cron.d/`)

| Layer | Script | When | Target | Retention |
|---|---|---|---|---|
| **A — config** | `pve-config-backup.sh` | daily 01:30 | `/tank/backups/host-config/pve-config-<date>.tar.gz` | 30 days |
| **B1 — system** | `pve-system-backup.sh` | Sun 03:30 | `/tank/backups/host-system/pve-system-<date>.tar.zst` | ~6 weeks |
| **off-host** | `host-offsite-sync.sh` | daily 04:30 | rsync A+B1 → `<offsite-host>:/backups/evilbot/` | mirrors source |
| **cloud** | `restic-offsite-backup.sh` | daily 04:00 | encrypted restic repo → Backblaze B2 | 7d/4w/3m |

- **A (config)** ≈ 66 KB/day. Contains `/etc/pve`, network, `/etc/ssh`, `/root/.ssh`, fstab,
  apt sources, sysctl, cron, `/usr/local/bin`, **+** a `MANIFEST.txt`, `dpkg-selections.txt`,
  and `disk-network-layout.txt` (the rebuild metadata).
- **B1 (system)** ≈ 4 GB. Whole root filesystem **except** regenerable bulk:
  `/var/lib/docker`, `/opt/ai` (models), `/var/lib/vz` (templates), logs, caches.
- Backups contain private keys → tarballs are `chmod 600`; the cloud copy is encrypted by
  restic; the off-host copy travels over SSH on the trusted LAN.

Three copies of each backup: **tank** (local) → **off-host machine** → **B2** (off-site, encrypted).

---

## Scenario 1 — "I made a bad config change on the host" (the common case)

You edited something under `/etc` (network, storage, a service unit) and broke it. You do
**not** need a full restore — pull the good copy of just that file from last night's tarball.

```bash
# List available config backups
ls -lt /tank/backups/host-config/

# Peek at what a file looked like in the backup (no extraction)
tar xzf /tank/backups/host-config/pve-config-2026-06-04.tar.gz -O etc/network/interfaces | less

# Restore ONE file to a scratch location, diff, then put it back
cd /tmp && tar xzf /tank/backups/host-config/pve-config-2026-06-04.tar.gz etc/network/interfaces
diff /tmp/etc/network/interfaces /etc/network/interfaces
cp /tmp/etc/network/interfaces /etc/network/interfaces
# apply: e.g. `ifreload -a`, or `systemctl restart <svc>`, or reboot
```

Restore a whole subtree (e.g. all of `/etc/pve`) the same way:
`tar xzf <backup>.tar.gz -C / etc/pve` (extracts in place — review first).

> `/etc/pve` is a FUSE filesystem (pmxcfs). Prefer restoring individual files inside it while
> `pve-cluster` is running, rather than overwriting the whole mount.

**If you locked yourself out / broke networking or boot:** boot the Proxmox ISO in rescue
mode (or `pct`/console from another host), mount the root LV, and copy the file back:
```bash
mount /dev/pve/root /mnt && tar xzf <backup> -C /mnt etc/network/interfaces && umount /mnt
```

---

## Scenario 2 — Lost the boot disk (bare-metal rebuild from B1)

1. Reinstall Proxmox VE from ISO onto the new disk (matching version — see `MANIFEST.txt`).
2. Get the latest `pve-system-*.tar.zst` (from tank, the off-host machine, or B2 — see Scenario 4).
3. Restore the OS over the fresh install:
   ```bash
   cd / && tar -I zstd -xpf /path/pve-system-<date>.tar.zst \
       --numeric-owner --overwrite
   ```
4. Reinstall packages recorded at backup time (catches anything not in the tar):
   ```bash
   tar xzf pve-config-<date>.tar.gz -O dpkg-selections.txt | dpkg --set-selections
   apt-get dselect-upgrade
   ```
5. Re-pull the excluded bulk:
   - Docker/ComfyUI: `docker compose up -d` from its compose dir (in `/opt` or `/etc`).
   - AI models: re-download into `/opt/ai` from their sources.
   - LXC/VM templates: `pveam update && pveam download ...`.
6. Reboot. Restore guests from `/tank/backups/vzdump` with `qmrestore` / `pct restore`.

---

## Scenario 3 — Restore from the cloud (B2) when tank is gone

```bash
source /root/.secrets/restic-b2.env
export B2_ACCOUNT_ID B2_ACCOUNT_KEY RESTIC_PASSWORD
REPO="b2:${B2_BUCKET}:${B2_PATH}"

restic -r "$REPO" snapshots                      # list what's there
restic -r "$REPO" restore latest --target /restore \
       --include /tank/backups/host-config        # pull just config, or omit --include for all
```
> Requires `RESTIC_PASSWORD` (in the env file **and** your password manager). Without it the
> cloud backups are unrecoverable — there is no reset.

## Scenario 4 — Restore from the off-host machine

Offsite host/user are in `/root/.secrets/offsite-sync.env`.
```bash
source /root/.secrets/offsite-sync.env
rsync -a "${OFFSITE_USER}@${OFFSITE_HOST}:${OFFSITE_BASE}/host-config/" /tank/backups/host-config/
rsync -a "${OFFSITE_USER}@${OFFSITE_HOST}:${OFFSITE_BASE}/host-system/" /tank/backups/host-system/
```

---

## Activation checklist (one-time, see README in proxmox-host/backup/)

- [ ] **Off-host:** fill `/root/.secrets/offsite-sync.env`, then add evilbot's
      `/root/.ssh/id_rsa.pub` to the offsite user's `~/.ssh/authorized_keys`.
- [ ] **Cloud:** create a B2 bucket + app key, fill `/root/.secrets/restic-b2.env`. First run
      auto-initializes the repo. Verify: `restic -r "$REPO" snapshots`.
- [ ] **Test a restore** quarterly (Scenario 1 is a 30-second drill).

## Verify backups are healthy

```bash
tail /var/log/pve-config-backup.log /var/log/pve-system-backup.log \
     /var/log/restic-offsite.log /var/log/host-offsite-sync.log
ls -lt /tank/backups/host-config/ | head
ls -lt /tank/backups/host-system/ | head
restic -r "$REPO" check        # cloud repo integrity (also runs automatically on Mondays)
```
