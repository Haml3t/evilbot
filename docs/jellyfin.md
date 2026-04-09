> This file is part of a public repo. No secrets stored here.
> See `CLAUDE.md` § "Security & Secret Hygiene".

# Jellyfin

**VM:** LXC vmid 400 | Debian 12 | 192.168.1.196 (DHCP — set a router reservation for MAC `BC:24:11:65:5E:40`)
**Access:** `ssh -J root@192.168.1.145 root@192.168.1.196`
**Role:** Media server — streams from `/tank/media`

---

## Service

- **Web UI / API:** `http://192.168.1.196:8096`
- **HTTPS:** `https://192.168.1.196:8920` (self-signed cert)
- Installed via official Jellyfin Debian repo (`repo.jellyfin.org`)
- Version: Jellyfin 10.11.8
- Runs as: `jellyfin` system user
- Service: `jellyfin.service` (enabled, starts on boot)

---

## Media

`/tank/media` from evilbot is bind-mounted read-only at `/media` inside the container.

Libraries configured in Jellyfin:

| Library | Path |
|---|---|
| Movies | `/media/Movies` |
| TV Shows | `/media/TV` |
| Books | `/media/Books` |
| Audiobooks | `/media/Audiobooks` |

The container is unprivileged — `/tank/media` must be world-readable on evilbot:
```bash
ssh root@192.168.1.145 "chmod -R o+rX /tank/media"
```
Re-run this if new content is added and Jellyfin can't read it.

---

## Android Client

1. Install **Jellyfin** from the Play Store
2. Open → Add Server → `http://192.168.1.196:8096`
3. The app may auto-discover on local network via mDNS

Must be on home WiFi for local access. Remote access requires Tailscale (not yet configured).

---

## Reprovisioning

IaC is in `vm-iac/jellyfin/`. To rebuild from scratch:

```bash
cd vm-iac/jellyfin
cp terraform.tfvars.example terraform.tfvars  # fill in token + SSH key
terraform init && terraform apply

# After apply, get the new IP:
ssh root@192.168.1.145 "pct exec 400 -- ip -4 addr show eth0"

# Install Jellyfin:
./provision.sh <new-ip>

# Make media readable:
ssh root@192.168.1.145 "chmod -R o+rX /tank/media"
```

Then complete the first-run wizard at `http://<ip>:8096`.

---

## Notes

- **Password reset:** Jellyfin's UI-based reset writes a PIN file to the server filesystem.
  If locked out, reset directly via SQLite:
  ```bash
  ssh -J root@192.168.1.145 root@192.168.1.196
  systemctl stop jellyfin
  python3 /tmp/reset.py  # see below
  systemctl start jellyfin
  ```
  Script (`/tmp/reset.py`):
  ```python
  import hashlib, os, sqlite3
  password = 'newpassword'
  salt = os.urandom(16)
  salt_hex = salt.hex().upper()
  key = hashlib.pbkdf2_hmac('sha512', password.encode(), bytes.fromhex(salt_hex), 210000)
  hash_str = f'$PBKDF2-SHA512$iterations=210000${salt_hex}${key.hex().upper()}'
  conn = sqlite3.connect('/var/lib/jellyfin/data/jellyfin.db')
  conn.execute("UPDATE Users SET Password=? WHERE Username='jellyfin'", (hash_str,))
  conn.commit()
  print('Done')
  ```

- **Transcoding:** 2-core LXC handles 1080p transcode fine; may struggle with 4K HDR.
  Prefer direct play in the Android app (set bitrate to Auto).

- **Tailscale / remote access:** Not yet configured. When added, requires TUN device
  passthrough in the LXC config (see `proxmox-host-safety.md` notes on Tailscale in LXC).
