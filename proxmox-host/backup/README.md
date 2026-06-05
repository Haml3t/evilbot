# evilbot host backup

Deployed to evilbot under `/usr/local/bin/` with cron units in `/etc/cron.d/` (see
`cron-entries.txt`). Full recovery procedures: [`docs/proxmox-host-backup-recovery.md`](../../docs/proxmox-host-backup-recovery.md).

| Script | Layer | Schedule | Output |
|---|---|---|---|
| `pve-config-backup.sh` | A — host config (66 KB) | daily 01:30 | `/tank/backups/host-config/` |
| `pve-system-backup.sh` | B1 — OS-core system tar (~4 GB) | Sun 03:30 | `/tank/backups/host-system/` |
| `host-offsite-sync.sh` | off-host copy → separate machine | daily 04:30 | `<offsite-host>:/backups/evilbot/` |
| `restic-offsite-backup.sh` | encrypted cloud → Backblaze B2 | daily 04:00 | restic repo on B2 |
| `zfs-snapshot-daily.sh` | ZFS snapshots (guest disks) | daily 01:00 | `tank/vmdata@daily-*` |

Three copies of every host backup: **tank** (local) → **off-host machine** → **B2** (off-site, encrypted).

## Activation (two one-time steps; both jobs skip cleanly until done)

**1. Off-host copy.** Set the target in `/root/.secrets/offsite-sync.env` (chmod 600, not in
git — see `offsite-sync.env.example`), then add evilbot's root key to that machine, as its user:
```bash
echo 'ssh-rsa AAAA...root@evilbot' >> ~/.ssh/authorized_keys   # evilbot:/root/.ssh/id_rsa.pub
```
Then test from evilbot: `/usr/local/bin/host-offsite-sync.sh`

**2. Cloud → Backblaze B2.**
1. backblaze.com → create a **private** bucket + an **application key** scoped to it.
2. Fill `B2_ACCOUNT_ID`, `B2_ACCOUNT_KEY`, `B2_BUCKET` in `/root/.secrets/restic-b2.env`
   (chmod 600, **never committed** — only `restic-b2.env.example` is in git).
3. `RESTIC_PASSWORD` is already generated in that file — **copy it to your password manager.**
4. First run auto-initializes the repo: `/usr/local/bin/restic-offsite-backup.sh`
