> This file is part of a public repo. No secrets are stored here — credentials are in
> untracked env files on the VM itself. See `CLAUDE.md` § "Security & Secret Hygiene".

# evilbot-nas

**VM:** QEMU vmid 100 | Ubuntu 24.04 LTS | 192.168.1.67  
**Access:** `ssh -J root@<proxmox-host> root@192.168.1.67`  
**Role:** NAS — torrent downloads, media file server, Samba shares

---

## Storage

`/tank` is virtiofs-mounted from the Proxmox host (22TB ZFS pool, ~33% used). The VM's own root disk is 64GB on `tank-vmdata`.

```
/tank/
  media/          # Organized library (Movies, TV, Books, Games, Upload, martial_arts/)
  watch/          # Drop .torrent files here to auto-start downloads
    media/
      Movies/     # → /tank/media/Movies/
      TV/         # → /tank/media/TV/
      Books/      # → /tank/media/Books/
      Games/      # → /tank/media/Games/
    private/      # → /tank/private/
    Processed/    # Torrents moved here after being picked up
  incomplete/     # In-progress downloads
  private/        # Private content (restricted Samba share)
  backups/
  isos/
  vmdata/
```

---

## Services

### Transmission (BitTorrent)

Daemon: `transmission-daemon.service`  
Web UI: `http://192.168.1.67:9091/transmission/`  
RPC whitelist: `127.0.0.1`, `192.168.*.*`, `10.*.*.*`, `100.*.*.*` (Tailscale)  
Credentials: in `/etc/transmission-remote.env` (not committed)

Config: `/etc/transmission-daemon/settings.json`
- Downloads to `/tank/media` (default) or dir determined by watch script
- Incomplete downloads go to `/tank/incomplete`
- Ratio limit: 2.0
- Queue: 5 simultaneous downloads

### transmission-watch

Service: `transmission-watch.service`  
Script: `/usr/local/bin/transmission-watch.sh`

Watches `/tank/watch` subdirectories with `inotifywait`. When a `.torrent` file appears, it:
1. Maps the watch subdir to the correct destination under `/tank/media/` or `/tank/private/`
2. Calls `transmission-remote --add <file> --download-dir <dest>`
3. Moves the `.torrent` to `Processed/` on success

**Watch dir → download dir mapping:**

| Watch path | Download destination |
|---|---|
| `watch/media/Movies/**` | `/tank/media/Movies/**` |
| `watch/media/TV/**` | `/tank/media/TV/**` |
| `watch/media/Books/**` | `/tank/media/Books/**` |
| `watch/media/Games/**` | `/tank/media/Games/**` |
| `watch/private/**` | `/tank/private/**` |
| anything else | `/tank/media/Upload` |

Subdirectory structure is preserved: dropping a torrent into `watch/media/Movies/Action/` will download into `/tank/media/Movies/Action/`.

Env: `/etc/transmission-remote.env` — holds `RPC_HOST`, `RPC_PORT`, `RPC_USER`, `RPC_PASS` (not committed)

### Samba

Config: `/etc/samba/smb.conf`  
Authentication: local Unix users; `map to guest = Bad User`

| Share | Path | Access |
|---|---|---|
| `media` | `/tank/media` | read: `mediagroup`; write: `mediaadmin`, `david` |
| `media_upload` | `/tank/media/Upload` | read/write: `mediauser`, `mediaadmin`, `david` (not browseable) |
| `martial_arts_ian` | `/tank/media/martial_arts/training_media/ian` | read/write: `ian`, `mediaadmin`, `david` |
| `private` | `/tank/private` | read/write: `mediaadmin`, `david` only |
| `tank_all` | `/tank` | read/write: `david` only (not browseable) |

Groups: `mediagroup`, `mediaadmingroup`, `iangroup`  
Local users: `david`, `ian`, `mediaadmin`, `mediauser`

### Tailscale

Running (`tailscaled.service`). Provides access to Tailscale network `gute-pierce.ts.net`.

---

## Adding a New Watch Category

1. Create the watch dir: `mkdir -p /tank/watch/<category>/`
2. Add a case to the `map_dest()` function in `/usr/local/bin/transmission-watch.sh`
3. `systemctl restart transmission-watch`
4. Optionally add a corresponding Samba share in `/etc/samba/smb.conf` + `systemctl reload smbd`
