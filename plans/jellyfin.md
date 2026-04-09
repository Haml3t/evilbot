# Plan: Jellyfin Media Server

**Goal:** Stream from `/tank/media` via a new LXC on evilbot. Accessible on the local
network and from Android.

---

## Status

- [x] Phase 1: Provision LXC via Terraform
- [x] Phase 2: Install & configure Jellyfin
- [x] Phase 3: Bind mount /tank/media
- [x] Phase 4: Connect Android client

---

## Phase 1: Provision LXC via Terraform

Use the existing `vm-iac/claudebot-lxc` Terraform config with a new tfvars.

**Suggested vmid:** 400  
**Hostname:** `jellyfin`  
**IP:** Static preferred (e.g. `192.168.1.100/24`) so the Android app always finds it.
Static IP requires either a DHCP reservation on your router (by MAC) or setting it in the
LXC config. DHCP reservation is easier — set it after first boot once you have the MAC.

**Spec:** 2 cores, 4096MB RAM (Jellyfin transcoding is CPU-hungry; bump to 8192MB and
4 cores if you plan to transcode rather than direct play), 32GB disk.

```hcl
# vm-iac/claudebot-lxc/jellyfin.tfvars  (gitignored)
proxmox_api_token = "terraform-lxc@pve!lxc=<token>"
vm_id            = 400
hostname         = "jellyfin"
ip_address       = "dhcp"   # set DHCP reservation on router after first boot
cpu_cores        = 2
memory_mb        = 4096
disk_storage     = "local-lvm"
disk_size_gb     = 32
template_file_id = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
ssh_public_key   = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICldwDWvxKtJtb4h2FtYDliLU+UQT4JoXeNWQkFc6aXS claudebot-to-evilbot"
```

```bash
terraform -chdir=vm-iac/claudebot-lxc apply -var-file=jellyfin.tfvars
```

> **Note:** The current Terraform config doesn't support bind mounts — the media mount
> is added manually in Phase 3 (Proxmox doesn't support bind mounts via the API the same
> way it does via pct/config file). This is a known gap; can be added to the Terraform
> module in Phase 4 of the IaC plan.

---

## Phase 2: Install & Configure Jellyfin

SSH into the new container:
```bash
ssh -J root@192.168.1.145 root@<jellyfin-ip>
```

Install Jellyfin from the official Debian repo:
```bash
apt-get install -y curl gnupg
curl -fsSL https://repo.jellyfin.org/jellyfin_team.gpg.key \
  | gpg --dearmor -o /usr/share/keyrings/jellyfin.gpg
echo "deb [signed-by=/usr/share/keyrings/jellyfin.gpg] https://repo.jellyfin.org/debian bookworm main" \
  > /etc/apt/sources.list.d/jellyfin.list
apt-get update && apt-get install -y jellyfin
systemctl enable --now jellyfin
```

Jellyfin listens on:
- `http://<ip>:8096` — web UI and API
- `https://<ip>:8920` — HTTPS (self-signed cert by default)

First-run setup is done via the web UI at `http://<ip>:8096`.

---

## Phase 3: Bind Mount /tank/media

The bind mount must be configured on the **Proxmox host**, not inside the container.
Stop the container first.

### Option A — pct set (simplest)
```bash
ssh root@192.168.1.145
pct stop 400
pct set 400 -mp0 /tank/media,mp=/media,ro=1
pct start 400
```

This mounts `/tank/media` from evilbot into the container at `/media` as read-only.

### UID mapping caveat (unprivileged LXC)
Unprivileged containers shift UIDs by 100000. Files owned by `root` on the host appear
as `nobody` (uid 65534) inside the container. Jellyfin runs as the `jellyfin` user (uid
varies) and needs read access to `/media`.

Fix — make the mount world-readable on the host:
```bash
chmod -R o+rX /tank/media
```

Or (better, no chmod needed) — add the jellyfin user's uid to the LXC's idmap so it can
read files owned by specific host uids. More complex; world-readable is fine for a
private homelab.

After mounting, configure Jellyfin libraries to use `/media`:
- Web UI → Dashboard → Libraries → Add Media Library
- Point to `/media/Movies`, `/media/TV`, etc.

---

## Phase 4: Connect Android Client

### Install the app
**Jellyfin for Android** — available on:
- [Google Play Store](https://play.google.com/store/apps/details?id=org.jellyfin.mobile)
- [F-Droid](https://f-droid.org/packages/org.jellyfin.mobile/)

### Connect on local network
1. Open the app → "Add Server"
2. Enter: `http://192.168.1.<jellyfin-ip>:8096`
3. Log in with the account created during web UI setup

The app will also auto-discover Jellyfin servers on the local network via mDNS — it may
appear automatically when you open the "Add Server" screen.

### Connect remotely (outside home network)
Requires Tailscale on the Jellyfin LXC (not yet installed in containers). Once Tailscale
is set up:
- Server address: `http://<jellyfin-tailscale-ip>:8096`
- Or use the Tailscale MagicDNS hostname

Tailscale setup in an unprivileged LXC requires the TUN device:
```
# In /etc/pve/lxc/400.conf on evilbot (add these lines):
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
```

### Direct play vs transcoding
- **Direct play** (preferred): tablet plays the file format natively, no CPU cost.
  Works well for H.264 MP4/MKV on Android.
- **Transcoding**: Jellyfin re-encodes on the fly if the client can't play the format.
  CPU-intensive — a 2-core LXC may struggle with 4K transcoding. 1080p is usually fine.

In the Android app settings: set "Max streaming bitrate" to Auto and prefer direct play.

---

## Open Questions

- Static IP via router DHCP reservation or LXC config? (Reservation is easier, no LXC
  restart needed if IP changes.)
- Transcoding needs? If 4K HDR content is in the library, consider bumping to 4 cores
  and enabling hardware transcoding (requires passing through the iGPU — complex on
  Proxmox, skip for now).
- Remote access: set up Tailscale on the Jellyfin LXC now or later?
- User accounts: single shared account or per-user accounts (david, ian, etc.)?
