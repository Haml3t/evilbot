# Plan: Proxmox Host Safety & Change Management

**Goal:** Ensure the Proxmox host (evilbot) is hardened, backed up, and only changed via
tested, reproducible IaC — never by ad-hoc SSH commands that can't be reviewed or rolled back.

Related but distinct from `iac-lxc.md` (which provisions *containers*). This plan governs
changes to the *host itself*.

---

## Status

- [x] Phase 1: SSH hardening — restrict claudebot's outbound access
- [ ] Phase 2: Proxmox host config as code (Ansible) ← **next priority**
- [x] Phase 3: Host backup strategy
- [ ] Phase 4: Staging / change validation workflow

---

## Phase 1: SSH Hardening — Restrict claudebot Outbound Access

**Problem:** claudebot can currently SSH to any host on the LAN. Claude (the AI) operates
this container, so its blast radius should be explicitly bounded.

**Goal:** claudebot can SSH to:
- `192.168.1.145` (evilbot) — jump host only
- `192.168.1.67` (evilbot-nas) via jump
- `192.168.1.239` (evilbot-telegram) via jump

And nowhere else.

### Option A — Proxmox firewall on the LXC (recommended)

Configure the container firewall in Proxmox to restrict *outbound* TCP/22 to the allowed
hosts. This is enforced at the hypervisor level — Claude cannot override it even if running
as root inside the container.

In `/etc/pve/firewall/300.fw` on evilbot:
```ini
[OPTIONS]
enable: 1

[RULES]
# Allow outbound SSH only to the proxmox host (jump target)
OUT ACCEPT -p tcp -d 192.168.1.145 --dport 22 -log nolog
# Block all other outbound SSH
OUT DROP -p tcp --dport 22 -log warning
```

Apply: `pve-firewall update` or via web UI (Datacenter → 300 → Firewall).

> Note: the NAS and Telegram VMs are reached *through* evilbot as a jump host, so
> their traffic goes via 192.168.1.145 and is covered by the first rule.

### Option B — nftables inside the container (defense in depth, secondary)

Can be added inside claudebot in addition to Option A, but should not be the *only* control
since root in the container can modify its own nftables rules.

### Verification

```bash
# From claudebot — should succeed
ssh root@192.168.1.145 hostname

# From claudebot — should be blocked/timeout
ssh root@192.168.1.1   # router
ssh root@192.168.1.100 # arbitrary LAN host
```

---

## Phase 2: Proxmox Host Config as Code (Ansible)

**Problem:** The Proxmox host has accumulated config (network bridges, storage pools, ZFS,
container/VM definitions, firewall rules, user accounts, API tokens) that exists only on the
host and is not reproducible from scratch.

**Goal:** All non-ephemeral host config is expressed in Ansible, committed to git, and
re-runnable idempotently. Running the playbook on a fresh Proxmox install should reproduce
the working state.

### What to codify

| Area | Proxmox path / mechanism | Ansible approach |
|---|---|---|
| Network (bridges, bonds) | `/etc/network/interfaces` | `template` module |
| ZFS pool config | `zpool.cache` + pool creation | `command` / custom role |
| Storage definitions | `/etc/pve/storage.cfg` | `template` or API |
| Container/VM base definitions | `/etc/pve/lxc/*.conf`, `/etc/pve/qemu-server/*.conf` | Managed by `iac-lxc.md` Terraform plan |
| Firewall rules | `/etc/pve/firewall/` | `template` module |
| Users & API tokens | Proxmox API | `uri` module or community.proxmox |
| Installed packages | `apt` | `apt` module |
| Cron jobs | `/etc/cron*` | `cron` module |
| Virtiofs shares | `/etc/pve/lxc/*.conf` section | Template |

### Directory layout

```
/root/infra/
  ansible/
    inventory.ini          # evilbot host
    playbooks/
      proxmox-host.yml     # Main playbook — applies full host config
      bootstrap.yml        # First-time setup (SSH keys, sudo, packages)
    roles/
      proxmox-network/
      proxmox-storage/
      proxmox-firewall/
      proxmox-users/
    group_vars/
      all.yml              # Non-secret vars
    vault/
      secrets.yml          # ansible-vault encrypted secrets (API tokens, passwords)
```

### Secret handling

Use `ansible-vault` for anything sensitive. The vault password lives in
`/root/.secrets/ansible-vault-pass` (gitignored). Commit only the encrypted vault file.

---

## Phase 3: Host Backup Strategy

**Two separate concerns:**

### 3a. VM/LXC data backups (already partially handled)

Proxmox has built-in `vzdump` for container/VM backups. The existing snapshots
(`pre-claude-20260409`, etc.) confirm this is in use. Formalise it:

- Schedule `vzdump` for all VMs/LXCs nightly → `/tank/backups/`
- Retention: keep 7 daily, 4 weekly
- Configure via Proxmox web UI: Datacenter → Backup, or via API

### 3b. Proxmox host config backup (not covered by vzdump)

`vzdump` backs up *guests*, not the host itself. The host config lives in:

```
/etc/pve/           # Cluster/node config, VM definitions, firewall rules, storage
/etc/network/       # Network interfaces
/etc/cron*/         # Cron jobs
```

Backup approach:
```bash
# Nightly script on evilbot → push to /tank/backups/host-config/
tar czf /tank/backups/host-config/pve-config-$(date +%F).tar.gz \
  /etc/pve /etc/network/interfaces /etc/cron.d /etc/cron.daily
# Retain 30 days
find /tank/backups/host-config/ -name '*.tar.gz' -mtime +30 -delete
```

Long-term: if Ansible fully codifies host config (Phase 2), the git repo *is* the backup.
The tar snapshots are a belt-and-suspenders fallback.

### 3c. Off-site / offload

`/tank/backups` lives on the same physical machine as the data — a single drive failure
or host compromise loses both. Future work: rsync backups to an off-site target (cloud
storage, a second physical machine, or a Tailscale-connected offsite node).

---

## Phase 4: Staging / Change Validation Workflow

**Problem:** Changes to the Proxmox host (new network config, storage changes, firewall
updates) are currently applied directly to the live host with no testing. A bad change
can take down all VMs.

**Goal:** Changes go through a review/test step before hitting the live host.

### Approach: Nested Proxmox VM as staging environment

Proxmox can run as a guest VM (with some limitations). The workflow:

```
1. Take a host config snapshot (tar of /etc/pve + Ansible state)
2. Spin up a nested Proxmox VM from a Proxmox ISO on evilbot
3. Apply the proposed Ansible change to the nested VM
4. Verify the change behaves correctly (network comes up, storage mounts, etc.)
5. If good → apply to live host via Ansible
6. If bad → discard the nested VM, revise the playbook
```

Limitations of nested Proxmox:
- ZFS may not be testable in a nested VM (no raw disk access)
- Network changes affecting `vmbr0` need careful handling (can lose connectivity)
- Hardware-dependent config won't transfer exactly

### Practical guard rails (lower effort, higher value first)

These can be implemented before a full staging VM is available:

1. **Git-gated changes:** All host config changes go through a git commit + review before
   `ansible-playbook` is run. No undocumented SSH changes.

2. **Dry-run first:** Always run `ansible-playbook --check --diff` before `--apply`.
   Output shows exactly what will change.

3. **Network change procedure:** Before changing `/etc/network/interfaces`, schedule an
   `at` job to revert the change 10 minutes later. If connectivity is lost, the revert
   fires automatically.
   ```bash
   echo "cp /etc/network/interfaces.bak /etc/network/interfaces && systemctl restart networking" | at now + 10 minutes
   # then make the change
   # if it works: atrm <job>
   ```

4. **Firewall changes via API only:** Never edit `/etc/pve/firewall/` by hand. API changes
   are logged and the Proxmox firewall has a built-in "enable" toggle that can be turned off
   without removing rules if something goes wrong.

5. **Pre-change snapshot:** Before any significant host change, snapshot all running VMs
   so guests can be rolled back even if the host config needs manual recovery.

### Longer-term: Blue-green host

True blue-green at the hypervisor level (two physical Proxmox nodes) is overkill for a
single-machine homelab. The practical equivalent is:

- A second Proxmox node (another small machine or a repurposed PC) in the same Tailscale
  network, configured identically via Ansible
- Not necessarily running all workloads — just "warm standby" that proves the Ansible
  playbook produces a working host

This also enables Proxmox Cluster setup (2-node with corosync tie-breaker), which enables
live migration of VMs between nodes.

---

## Open Questions

- Should the Ansible repo live in this claudebot container (`/root/infra/ansible/`) or on
  evilbot itself? (Here is safer — evilbot changes don't affect the repo.)
- What's the off-site backup target? Cloud (Backblaze B2, S3) or a second physical machine?
- Is a second Proxmox node feasible? What hardware is available?
- Should network-changing Ansible tasks always include the auto-revert `at` job, enforced
  by a custom Ansible callback plugin?
