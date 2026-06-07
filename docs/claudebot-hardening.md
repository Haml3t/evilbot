# Claudebot Security Hardening

How the blast radius of **claudebot** (the AI-operated workspace LXC, vmid 300) against
the Proxmox host **evilbot** is bounded. This complements
[`security-risk-assessment.md`](security-risk-assessment.md) and the
[`proxmox-host-safety.md`](../plans/proxmox-host-safety.md) plan.

## Threat model

claudebot is operated by an AI (Claude) and is explicitly **not** production infrastructure.
The concern is a *rogue or erroneous command* — issued by the model or by a human operator —
causing **irreversible** loss to the Proxmox host or its 22 TB `tank` pool. Two paths
historically made that a one-command event:

1. **Unrestricted root SSH** — claudebot's key was trusted as full root on evilbot with no
   forced command, so `ssh root@evilbot "zfs destroy -r tank"` would just run.
2. **Over-privileged API token** — the Terraform token held `PVEAdmin` on `/`,
   `/nodes/evilbot`, and `/storage/local-lvm` (privsep=0), able to delete disks / free
   datastore space across the whole host.

Compounding factor: **every backup currently lives on `tank`** (vzdump, ZFS snapshots, host
tars), so a `zpool destroy tank` is unrecoverable. An off-pool immutable copy is still
outstanding (see "Open" below).

## Controls implemented

### 1. Least-privilege Proxmox token

The Terraform token (`terraform-lxc@pve!lxc`) was rotated and re-scoped to a custom role
with **privilege separation on (privsep=1)**:

| Path | Role | Effect |
|---|---|---|
| `/` | `PVEAuditor` | read-only everything (keeps the provider's reads working) |
| `/pool/claudebots` | `ClaudebotLXC` | full container lifecycle, scoped to the pool |
| `/storage/local-lvm` | `ClaudebotLXC` | allocate **space** for container disks |
| `/sdn/zones/localnetwork` | `PVESDNUser` | attach container networking |

The custom `ClaudebotLXC` role grants the LXC-lifecycle privileges (`VM.Allocate`,
`VM.Config.*` incl. `VM.Config.Disk`, `Datastore.AllocateSpace`, `Pool.Allocate/Audit`,
`SDN.Use`) but **deliberately excludes** `Sys.PowerMgmt`, `Sys.Modify`,
`Datastore.Allocate`, `User.Modify`, and `Realm.AllocateUser` — i.e. it can build containers
in its own pool but cannot touch the host node or destroy/modify storage.

Verified after rotation: `GET /version`, pool, node and storage reads return `200`; a
`POST /nodes/evilbot/status` reboot returns **`403`**. No `PVEAdmin` grant remains on the
token. The secret lives only in gitignored `*.tfvars` / `.secrets/` — never in this repo.

> This is the concrete implementation of the "minimum scope" rule in
> [`CLAUDE.md` → Proxmox API Token Policy](../CLAUDE.md). Note the parent *user*
> `terraform-lxc@pve` still carries dormant broad ACLs (inert under privsep=1) — a candidate
> for a later cleanup.

### 2. ZFS destroy guard (snapshot holds)

A recursive `tank@keep-<date>` snapshot is pinned with a `guard` hold on every dataset
(`tank`, `tank/backups`, `tank/isos`, `tank/vmdata`, …). A held snapshot cannot be
destroyed, so **`zfs destroy -r tank` fails** until someone explicitly runs:

```bash
zfs release -r guard tank@keep-<date>
```

The `keep-` snapshot sits outside the 14-day `@daily-` prune, so it persists. **Caveat:**
holds do *not* stop `zpool destroy` (that nukes the pool regardless) — that case is covered
only by the access controls and the approval hook below.

### 3. Claude command-approval hook

A Claude Code **PreToolUse hook** ([`../claude-guardrails/guard-destructive.py`](../claude-guardrails/guard-destructive.py))
returns `permissionDecision: "ask"`, forcing a **per-command human approval prompt** before
execution. It overrides both the permission allow-list and auto-mode, so these never run
unattended. Four tiers prompt:

1. **Catastrophic** — `zpool/zfs destroy`, `zfs rollback`, `pct/qm destroy`, `mkfs`,
   `wipefs`, `dd of=/dev/*`, `rm -rf` on a sensitive path/unquoted var (matched even inside
   an `ssh root@evilbot "…"` payload, which permission rules can't see).
2. **Remote/infra** — any `ssh`/`scp` to a host.
3. **Host-mutating from claudebot itself** — `terraform apply|destroy`, local `pveum`,
   mutating Proxmox API calls (`curl -X POST/PUT/DELETE … :8006`).
4. **Self-modification** — edits to the agent's own settings, hooks, `CLAUDE.md`, or SSH
   trust files.

Ordinary local work and read-only Proxmox `GET`s pass through untouched. The hook fails
**open** on a parse error so it can never wedge the harness.

> **Operational lesson:** in auto mode (`skipAutoPermissionPrompt`), *removing* an allow rule
> does **not** make a command prompt — the auto-mode classifier silently approves it. The
> only ways to force a real per-command prompt are (a) a hook returning `"ask"`, or
> (b) leaving auto mode. Hooks added mid-session are not live until `/hooks` is reopened or
> the session restarts — verify with a harmless `ssh root@evilbot hostname` and confirm a
> prompt appears.

### 4. SSH key — left as root, guarded by the hook

claudebot's key remains root on evilbot (CLAUDE.md designs claudebot to manage the host).
Rather than a forced-command allowlist (which trades away management flexibility and risks
lockout), the per-command approval hook (tier 2) is the guard: every SSH command stops for
human approval.

## Open

- **Off-pool immutable backup** — all backups still live on `tank`; a `zpool destroy` loses
  them. Cloud (Backblaze B2 + Object Lock / append-only restic key) or a snapshotted dataset
  on an off-host target is the remaining gap. See
  [`proxmox-host-backup-recovery.md`](proxmox-host-backup-recovery.md).
- **Append-only command audit** on evilbot (e.g. `auditd` execve rules) so a rogue root
  command leaves a tamper-evident trail.
- **Reduce the dormant broad ACLs** on the `terraform-lxc@pve` *user*.
