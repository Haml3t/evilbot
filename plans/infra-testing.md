# Plan: IaC Verification, Backup/Restore & Automated Testing

**Goal:** Every system in this homelab can be reproduced from IaC or backup, verified
automatically, and proven to work — not just assumed to work because it worked once.

Related plans: `proxmox-host-safety.md` (backup strategy), `iac-lxc.md` (Terraform module)

---

## Status

- [ ] Phase 1: IaC completeness audit
- [ ] Phase 2: Backup strategy & scheduling
- [ ] Phase 3: Automated restore verification
- [ ] Phase 4: Service functional test suite
- [ ] Phase 5: CI/CD — run tests on every push

---

## Phase 1: IaC Completeness Audit

For each system, answer: *"If this VM/LXC were destroyed right now, could we reproduce it
from code alone?"*

| System | IaC exists | Post-provision scripted | Secrets documented | Verdict |
|---|---|---|---|---|
| claudebot (vmid 300) | ✅ `vm-iac/claudebot-lxc/` | ❌ manual | ✅ | Partial — needs provision script |
| jellyfin (vmid 400) | ✅ `vm-iac/jellyfin/` | ✅ `provision.sh` | ✅ | ✅ Complete |
| evilbot-nas (vmid 100) | ⚠️ `vm-iac/evilbot-nas-iac/` (old Telmate provider, incomplete) | ❌ | ⚠️ | Incomplete |
| evilbot-telegram (vmid 200) | ❌ | ❌ | ⚠️ | Not covered |
| evilbot (Proxmox host) | ❌ | ❌ | — | Not covered (see proxmox-host-safety.md) |

### Gaps to close

1. **claudebot provision script** — mirror `vm-iac/jellyfin/provision.sh`; install Node 22,
   Python 3, Claude Code CLI, git
2. **evilbot-nas IaC** — migrate from `Telmate/proxmox` + password to `bpg/proxmox` + token;
   add Ansible playbook to install Transmission, Samba, watch script
3. **evilbot-telegram IaC** — Terraform + provision script; install Python venv, evilbot.py,
   systemd service; `.env` secrets stored in ansible-vault or documented placeholder
4. **Proxmox host** — see `proxmox-host-safety.md` Phase 2 (Ansible)

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
BACKUP=$(ssh root@192.168.1.145 "ls -t /tank/backups/vzdump-*-${SOURCE_VMID}-*.vma.zst 2>/dev/null | head -1")

[[ -z "$BACKUP" ]] && { echo "No backup found for vmid $SOURCE_VMID"; exit 1; }

echo "Restoring $BACKUP as vmid $TEST_VMID..."
ssh root@192.168.1.145 "qmrestore $BACKUP $TEST_VMID --force 2>&1 || pct restore $TEST_VMID $BACKUP --force 2>&1"
ssh root@192.168.1.145 "pct start $TEST_VMID"
sleep 15

# Get IP
TEST_IP=$(ssh root@192.168.1.145 "pct exec $TEST_VMID -- ip -4 addr show eth0 | grep -oP '(?<=inet )[^/]+'")
echo "Test container IP: $TEST_IP"

# Run service-specific tests (sourced from tests/)
source "tests/${SOURCE_VMID}.sh"
run_tests "$TEST_IP"

# Cleanup
ssh root@192.168.1.145 "pct stop $TEST_VMID && pct destroy $TEST_VMID"
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

Use a **self-hosted GitHub Actions runner** on claudebot. On every push to `main`:
1. Run the BATS test suite against live services (smoke test — fast)
2. Weekly: run the full IaC reprovision test for Jellyfin (slower)

### Setup

```bash
# On claudebot — install GitHub Actions runner
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

---

## Open Questions

- Where does the self-hosted runner run — claudebot (vmid 300) or a dedicated runner LXC?
- Should the weekly IaC reprovision test use a spare VMID range (e.g. 900-999)?
- Backup storage: add `/tank/backups` as a Proxmox storage now, or wait until Ansible
  manages the host config?
- Should failed tests send a Telegram notification via evilbot?
  (Good use of the existing bot — infra alerting.)
