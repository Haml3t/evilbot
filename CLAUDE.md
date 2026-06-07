# Claude Code — claudebot

## This Environment

This is **claudebot** — an unprivileged Debian 12 LXC container (vmid 300) running on the Proxmox host **evilbot**. It is a general-purpose AI workspace: write code here, run experiments, manage infrastructure, and SSH out to other machines.

- **Container IP:** 192.168.1.222
- **Proxmox host:** evilbot — 192.168.1.145 (6 cores, ~47 GB RAM)
- **Tailscale domain:** `<tailnet>.ts.net` (Tailscale CLI not yet installed in this container)

## Host & VM Topology

| Name | Type | IP | Access | Notes |
|---|---|---|---|---|
| evilbot | Proxmox host | 192.168.1.145 | `ssh root@192.168.1.145` ✅ | 22TB ZFS pool `tank` |
| evilbot-nas | QEMU VM (vmid 100) | 192.168.1.67 | `ssh -J root@192.168.1.145 root@192.168.1.67` ✅ | Custom Linux NAS; /tank shared in via virtiofs |
| evilbot-telegram | QEMU VM (vmid 200) | 192.168.1.238 | `ssh -J root@192.168.1.145 root@192.168.1.238` ✅ | Telegram bot (no GPU); calls IMAGEGEN_URL; Ubuntu; no guest agent — IP via DHCP, was .239 |
| jellyfin | LXC (vmid 400) | 192.168.1.196 | `ssh -J root@192.168.1.145 root@192.168.1.196` ✅ | Jellyfin media server; /tank/media bind-mounted at /media |
| claudebot | LXC (vmid 300) | 192.168.1.222 | this container | |

To reach NAS or Telegram VMs: proxy through evilbot (`-J root@192.168.1.145`). Claudebot's pubkey is already in `authorized_keys` on both.

## SSH Key

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICldwDWvxKtJtb4h2FtYDliLU+UQT4JoXeNWQkFc6aXS claudebot-to-evilbot
```
This key is already trusted by evilbot root.

## ZFS Tank Structure (on evilbot at /tank, shared into NAS VM)

```
/tank/
  media/          # Organized media library (Movies, TV, Audiobooks, Books, etc.)
  watch/          # Torrent watch folders — dropping a .torrent here auto-starts download
    audiobooks/
    media/
    private/
    Processed/    # Watch folders that have been picked up
  incomplete/     # In-progress torrent downloads
  backups/        # VM/system backups
  isos/           # OS ISOs
  vmdata/         # VM disk images (ZFS pool tank/vmdata)
```

To add a new watch folder category: create the directory under `/tank/watch/` on evilbot (or inside the NAS VM if it manages its own watch config), then add the corresponding path to the torrent client's watch folder list (config lives on the NAS VM — SSH access needed to confirm exact client and config path).

## Tools Installed

- Node.js 22, npm 10
- Python 3, pip
- git 2.39.5
- curl, wget
- Claude Code CLI (`claude`)

Not installed yet: Terraform, Tailscale, docker, ansible

## Security & Secret Hygiene

This repo is **public on GitHub**. Full policy: [`SECURITY.md`](SECURITY.md).
Pre-commit/pre-push scans and the "secret already committed" runbook:
[`docs/publishing-checklist.md`](docs/publishing-checklist.md). Before
committing anything, apply these rules.

**Never commit:**
- Passwords or API secrets of any kind
- `**/*.tfvars` and `**/*.tfstate*` (state + backups) — extension globs, not
  exact names. The old exact-name patterns missed `jellyfin.tfvars` (live
  Proxmox API token) and `terraform-301.tfstate` (passwords). Only
  `**/*.tfvars.example` / `**/*.tfstate.example` are allowed through.
- Any `**/.env` file (e.g. `devbox-secrets.env`, `restic-b2.env`)
- Devbox private-context files: `**/devbox/CLAUDE.md.template` and
  `**/devbox/repos.txt` (employer-internal architecture + private work-repo
  names). Only their `*.example` versions are public.
- Tailscale auth keys / the real tailnet name (use `<tailnet>` / `<tailscale-ip>`)
- Ansible vault secrets (commit only the encrypted vault file, never plaintext)
- The Telegram bot token (`TELEGRAM_BOT_TOKEN` lives on the VM in `/opt/evilbot/.env`)
- Transmission RPC password (`/etc/transmission-remote.env` on the NAS)
- Proxmox API token secrets (use `*.tfvars.example` with placeholders instead)
- Real personal identities (names, personal folder names, personal/employer
  commit-author emails) or any employer-internal content
- `.safety-denylist` — the local file holding the real sensitive terms the scan
  commands grep for (only `.safety-denylist.example` is public)

**Safe to commit as-is:**
- LAN IPs (`192.168.1.x`) — RFC1918, not routable from the internet
- SSH public keys — public by design
- Config structure, scripts, and plans with secrets replaced by env var references
- Architecture docs and plans

**For every secret-bearing config file, commit a sanitized `*.example` alongside it.**

See `/root/.claude/plans/github-sync.md` for the project-internal publishing plan.

## Active Projects

See `/root/.claude/plans/` for in-progress implementation plans.

1. **IaC for Claude sandbox containers** — Terraform + Proxmox provider to clone and provision new claudebot-style LXC containers on evilbot — plan: `iac-lxc.md`
2. **Documentation pass** ✅ — See `/root/docs/evilbot-nas.md` and `/root/docs/evilbot-telegram.md`
3. **Jellyfin** ✅ — LXC vmid 400 at 192.168.1.196:8096; IaC in `vm-iac/jellyfin/`; docs in `docs/jellyfin.md`
4. **Remote Claude access** ✅ — SSH via jump host works for all VMs; see topology table above
5. **GitHub sync** — Sync this repo to GitHub; portfolio-safe publishing — plan: `github-sync.md`
6. **Proxmox host safety** — SSH hardening, host config as Ansible IaC, backups, staged change workflow — plan: `proxmox-host-safety.md`
7. **IaC verification & automated testing** — audit IaC completeness, backup/restore verification, BATS functional tests per service, GitHub Actions CI on self-hosted runner — plan: `infra-testing.md`

## Working with evilbot Proxmox

```bash
# List containers/VMs
ssh root@192.168.1.145 "pvesh get /nodes/evilbot/lxc"
ssh root@192.168.1.145 "pvesh get /nodes/evilbot/qemu"

# Start/stop a container
ssh root@192.168.1.145 "pct start 300"
ssh root@192.168.1.145 "pct stop 300"

# Execute command inside an LXC
ssh root@192.168.1.145 "pct exec 300 -- bash -c 'hostname'"

# Proxmox web UI
https://192.168.1.145:8006
```

### Proxmox API Token Policy

Prefer API tokens over `ssh root@192.168.1.145` for automation. Use the minimum scope needed:

| Token purpose | Permissions to grant |
|---|---|
| Read-only inspection / planning | `VM.Audit`, `Datastore.Audit` on relevant pools |
| Container management (start/stop/create LXC) | `VM.PowerMgmt`, `VM.Config.HWType`, `VM.Config.Options`, `Pool.Allocate` — scoped to a specific pool or vmid range |

**Never combine** `Sys.PowerMgmt` + `Datastore.Allocate` + `VM.Config.Disk` in a single token — that combination can irreversibly destroy storage. When in doubt, use the read-only token first and escalate only as needed.

**Implemented:** the `terraform-lxc@pve!lxc` token runs with privilege separation (privsep=1)
under a custom `ClaudebotLXC` role scoped to `/pool/claudebots` + `/storage/local-lvm`, with
read-only `PVEAuditor` on `/` — no `PVEAdmin` anywhere, and none of the dangerous trio above.
See [`docs/claudebot-hardening.md`](docs/claudebot-hardening.md) and
[`claude-guardrails/`](claude-guardrails/) for the full hardening posture.

Tokens are created at: Datacenter → Permissions → API Tokens in the web UI.

## Notes & Gotchas

- This container is **unprivileged** — no direct access to host devices or kernel modules. Tailscale requires TUN device; set `lxc.cgroup2.devices.allow = c 10:200 rwm` and `dev tun` in container config on evilbot if needed.
- The NAS VM's torrent client watches `/tank/watch/*` — the actual watch folder path inside the VM may differ from the host path depending on how virtiofs mounts it.
- evilbot-telegram (vmid 200) has no QEMU guest agent installed; its IP must be found via ARP or DHCP leases on the router.
- Proxmox API tokens: see "Proxmox API Token Policy" section above.
