# Plan: IaC Verification, Backup/Restore & Automated Testing

**Goal:** Every system in this homelab can be reproduced from IaC or backup, verified
automatically, and proven to work — not just assumed to work because it worked once.

Related plans: `proxmox-host-safety.md` (backup strategy), `iac-lxc.md` (Terraform module)

---

## Status

- [x] Phase 1: IaC completeness audit
- [x] Phase 2: Backup strategy & scheduling
- [ ] Phase 3: Automated restore verification
- [ ] Phase 4: Service functional test suite
- [ ] Phase 5: CI/CD — run tests on every push

---

## Phase 1: IaC Completeness Audit

For each system, answer: *"If this VM/LXC were destroyed right now, could we reproduce it
from code alone?"*

| System | IaC exists | Post-provision scripted | Secrets documented | Verdict |
|---|---|---|---|---|
| claudebot (vmid 300) | ✅ `vm-iac/claudebot-lxc/` | ✅ `provision.sh` | ✅ | ✅ Complete |
| jellyfin (vmid 400) | ✅ `vm-iac/jellyfin/` | ✅ `provision.sh` | ✅ | ✅ Complete |
| evilbot-nas (vmid 100) | ✅ `vm-iac/evilbot-nas-iac/` (migrated to bpg/proxmox + token) | ✅ `provision.sh` | ✅ | ✅ Complete |
| evilbot-telegram (vmid 200) | ✅ `vm-iac/evilbot-telegram/` | ✅ `provision.sh` | ✅ | ✅ Complete |
| evilbot (Proxmox host) | ⏳ | ⏳ | — | In progress — see `proxmox-host-safety.md` Phase 2 (Ansible) |

### Remaining gap

**Proxmox host IaC** — Ansible playbook to codify network config, storage definitions,
firewall rules, user/token setup, and installed packages. This is the last system without
reproducible provisioning. Tracked in `proxmox-host-safety.md` Phase 2.

---

## Phase 2: Backup Strategy & Scheduling

### 2a. LXC/VM backups via vzdump

Schedule nightly `vzdump` for all containers and VMs → `/tank/backups/`.

```bash
# On evilbot — add to /etc/cron.d/pve-backups or configure via Proxmox web UI
# Datacenter → Backup → Add schedule
#   Storage: tank-backups (needs to be added as a storage in Proxmox)
#   Schedule: 02:00 daily
#   VMs: 100, 200, 300, 400
#   Mode: snapshot
#   Retention: keep-daily=7, keep-weekly=4
```

Add `/tank/backups` as a Proxmox backup storage:
```bash
pvesm add dir tank-backups --path /tank/backups --content backup
```

### 2b. Host config backup

Nightly tar of `/etc/pve` + network config → `/tank/backups/host-config/`

```bash
# /etc/cron.daily/pve-config-backup
#!/bin/bash
tar czf /tank/backups/host-config/pve-$(date +%F).tar.gz \
  /etc/pve /etc/network/interfaces
find /tank/backups/host-config/ -name '*.tar.gz' -mtime +30 -delete
```

### 2c. Backup verification checklist (manual, monthly)

- [ ] At least one `.vma.zst` backup exists for each VMID in `/tank/backups/`
- [ ] Backups are < 24h old
- [ ] Host config tar exists and is < 24h old
- [ ] At least one backup was successfully restored (see Phase 3)

---

## Phase 3: Automated Restore Verification

**Goal:** Prove that a backup can actually produce a working system. Run monthly or
on-demand after significant changes.

### Restore test procedure (shell script)

```bash
#!/usr/bin/env bash
# restore-test.sh <vmid> <test-vmid>
# Restores the latest backup of <vmid> to a temporary <test-vmid>,
# runs health checks, then destroys the test container.
set -euo pipefail

SOURCE_VMID=${1:?}
TEST_VMID=${2:?}
BACKUP=$(ssh root@192.168.0.145 "ls -t /tank/backups/vzdump-*-${SOURCE_VMID}-*.vma.zst 2>/dev/null | head -1")

[[ -z "$BACKUP" ]] && { echo "No backup found for vmid $SOURCE_VMID"; exit 1; }

echo "Restoring $BACKUP as vmid $TEST_VMID..."
ssh root@192.168.0.145 "qmrestore $BACKUP $TEST_VMID --force 2>&1 || pct restore $TEST_VMID $BACKUP --force 2>&1"
ssh root@192.168.0.145 "pct start $TEST_VMID"
sleep 15

# Get IP
TEST_IP=$(ssh root@192.168.0.145 "pct exec $TEST_VMID -- ip -4 addr show eth0 | grep -oP '(?<=inet )[^/]+'")
echo "Test container IP: $TEST_IP"

# Run service-specific tests (sourced from tests/)
source "tests/${SOURCE_VMID}.sh"
run_tests "$TEST_IP"

# Cleanup
ssh root@192.168.0.145 "pct stop $TEST_VMID && pct destroy $TEST_VMID"
echo "Restore test PASSED for vmid $SOURCE_VMID"
```

### IaC reprovision test procedure

Same idea but uses `terraform apply` + provision script instead of backup restore:

```bash
# iac-test.sh <service>
# Provisions a fresh container, runs health checks, destroys it.
# Proves the IaC + provision script can reproduce a working system.
```

---

## Phase 4: Service Functional Test Suite

Tests live in `tests/` directory. One file per service. Uses
**[BATS](https://github.com/bats-core/bats-core)** (Bash Automated Testing System) —
lightweight, no dependencies beyond bash.

```
tests/
  helpers.bash        # shared: ssh_exec(), wait_for_port(), http_check()
  400-jellyfin.bats   # Jellyfin tests
  300-claudebot.bats  # claudebot tests
  100-nas.bats        # NAS tests
  200-telegram.bats   # Telegram bot tests
```

### Test spec per service

**Jellyfin (vmid 400)**
```bash
@test "Jellyfin HTTP responds" {
  http_check "http://$IP:8096/health" 200
}
@test "Jellyfin API returns server info" {
  result=$(curl -sf "http://$IP:8096/System/Info/Public")
  echo "$result" | grep -q "ServerName"
}
@test "/media mount is populated" {
  file_count=$(ssh_exec $IP "ls /media | wc -l")
  [ "$file_count" -gt 0 ]
}
@test "Jellyfin service is enabled" {
  ssh_exec $IP "systemctl is-enabled jellyfin"
}
```

**claudebot (vmid 300)**
```bash
@test "SSH accessible" {
  ssh_exec $IP "hostname" | grep -q "claudebot"
}
@test "Node.js installed" {
  ssh_exec $IP "node --version" | grep -q "v22"
}
@test "Claude Code CLI installed" {
  ssh_exec $IP "claude --version"
}
@test "Python 3 installed" {
  ssh_exec $IP "python3 --version"
}
```

**evilbot-nas (vmid 100)**
```bash
@test "Transmission RPC responds" {
  http_check "http://$IP:9091/transmission/rpc" 409  # 409 = auth required = alive
}
@test "Samba is running" {
  ssh_exec $IP "systemctl is-active smbd"
}
@test "transmission-watch is running" {
  ssh_exec $IP "systemctl is-active transmission-watch"
}
@test "/tank is mounted" {
  ssh_exec $IP "mountpoint /tank"
}
```

**evilbot-telegram (vmid 200)**
```bash
@test "evilbot service is running" {
  ssh_exec $IP "systemctl is-active evilbot"
}
@test "Python venv exists" {
  ssh_exec $IP "test -f /opt/evilbot/venv/bin/python"
}
@test "database exists" {
  ssh_exec $IP "test -f /opt/evilbot/evilbot.db"
}
```

---

## Phase 5: CI/CD — Run Tests on Every Push

Use a **self-hosted GitHub Actions runner**. On every push to `main`:
1. Run the BATS test suite against live services (smoke test — fast)
2. Weekly: run the full IaC reprovision test for Jellyfin (slower)

> **Correction (2026-08-31, Hermes agent).** The plan below places the runner on
> **claudebot (vmid 300)**. That is no longer right: claudebot is explicitly
> "another agent's workspace, not infrastructure" (§2 of the handoff) and is the
> only host deliberately excluded from Hermes' access. A CI runner on it would be
> unreachable, unmaintainable, and wrong per the access model. The runner belongs
> on a host Hermes can administer — **opsbot (600)** or **inferbot (500)**, both
> Tier 1/2 — or a new dedicated runner LXC. Open question 1 below stays open but
> claudebot is ruled out.

### Setup

```bash
# On the runner host (opsbot/inferbot, NOT claudebot) — install GitHub Actions runner
mkdir -p /opt/actions-runner && cd /opt/actions-runner
curl -o runner.tar.gz -L https://github.com/actions/runner/releases/latest/download/actions-runner-linux-x64-*.tar.gz
tar xzf runner.tar.gz
./config.sh --url https://github.com/Haml3t/evilbot --token <runner-token>
./svc.sh install && ./svc.sh start
```

### Workflow (`.github/workflows/infra-tests.yml`)

```yaml
name: Infrastructure Tests
on:
  push:
    branches: [main]
  schedule:
    - cron: '0 6 * * 1'  # Weekly Monday 6am

jobs:
  smoke-tests:
    runs-on: self-hosted
    steps:
      - uses: actions/checkout@v4
      - name: Install BATS
        run: sudo apt-get install -y bats
      - name: Run service smoke tests
        run: bats tests/
```

### CI blocker discovered 2026-08-31 (do not discover it again)

`main` now has **branch protection** (require a pull request, block force push,
block deletions). A self-hosted runner needs a registration token from
`repo → Settings → Actions → Runners`, and a runner that can reach the fleet to
run live smoke tests also has the credentials to write secrets. Treat the
runner's SSH key and any token on it as Tier 1/2-equivalent: scoped to the
fleet it tests, rotated, and audited. This is the same authority-tier reasoning
as `grant-hermes-sudo.sh`.

---

## Open Questions

- Where does the self-hosted runner run — ~~claudebot (vmid 300)~~ or a dedicated
  runner LXC? (Ruled out claudebot 2026-08-31; prefer opsbot/inferbot.)
- Should the weekly IaC reprovision test use a spare VMID range (e.g. 900-999)?
- Backup storage: add `/tank/backups` as a Proxmox storage now, or wait until Ansible
  manages the host config?
- Should failed tests send a Telegram notification via evilbot?
  (Good use of the existing bot — infra alerting.)

## Reconciliation notes (2026-08-31, Hermes agent)

Facts that have drifted since this plan was written; the plan body above is
left intact except where explicitly corrected:

1. **evilbot-nas "Complete" verdict is too strong.** Phase 1's table marks
   `evilbot-nas` ✅ Complete with a "migrated to bpg/proxmox" note. The Terraform
   module is now hardened (pinned MAC, discard/ssd, ostype, outputs, pool_id
   warning — see `fix/nas-iac-status-and-gaps`, merged) but is still
   *verified-by-inspection only*: no `terraform plan` against the live host has
   run because that needs the `terraform-lxc@pve!lxc` token, which lives in the
   secrets vault that is only now being built. Bump the verdict to "module
   exists + validates; not yet plan-verified against live host."
2. **Phase 3's `pct restore` / `qm restore` binary is fragile.** The script
   guesses the tool from VMID parity; VM 100 is a qemu VM (`qm`), containers are
   `pct`, and the `||` fallback would mis-restore on a partial failure. Worth
   pinning per-service in the helper, not probing.
3. **The NAS "service" is a trap.** `transmission-watch` is a custom unit, not a
   package service — Phase 4 already tests it, correctly, but the `restart the
   daemon after any watch change` trap (inventory) should be a BATS test too:
   restart `transmission-daemon`, then assert `transmission-watch` is still
   active.
4. **The donnertune/vLLM service is absent** from both the IaC table and the
   test suite (it postdates this plan). When it lands on gpu-desktop it needs its own
   smoke test: `:8000/v1/models` returns the fp8 model, and a completion returns
   the `[donnerism]` format.

