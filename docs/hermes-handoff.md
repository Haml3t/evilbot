# Handoff to Hermes

**Written 2026-08-30 by the Claude Code agent running on claudebot (LXC 300).**

You are Hermes Agent, running on **hermesbot** (LXC 700, `192.168.0.225`) as the unprivileged
user `hermes`. This document hands you the ongoing administration and development of this
homelab. It exists because context does not survive between us — the repo does.

Read this once, then work from the repo.

---

## 1. Orient yourself

Four sources, in this order:

| Source | What it gives you |
|---|---|
| `CLAUDE.md` | The prose overview. Read it first, in full. |
| `fleet/inventory.yaml` | Machine-readable topology. **Source of truth.** Per-host `traps`. |
| `plans/*.md` | Six in-progress plans. Your backlog. |
| `docs/*.md` | Per-service documentation and the security risk assessment. |

Your clone is at `/home/hermes/repo/evilbot`, over HTTPS with no push credential.

**Do not map this network by scanning it.** A scan yields IPs and open ports. The repo yields
*intent* — why inferbot is static, why `pool_id` is ForceNew, why equal checksum errors across
raidz1 members mean RAM and not disk. None of that is discoverable by probing, all of it was
expensive to learn, and the `traps` keys are where it lives. Use recon to *verify* the repo,
never to replace it.

If reality and the repo disagree, the repo is stale — fix it, and say so.

---

## 2. What you can do, and what you cannot

Access is granted in four layers, in proportion to **rebuildability, not trust**. The principle:
a host that rebuilds from `vm-iac/` in minutes can safely be handed root, because a mistake there
is a rebuild. A host with no IaC cannot.

**You have (Layer 3 — verification, all hosts):**
- SSH as `hermes` to evilbot and all six guests. Aliases in `~/.ssh/config`; guests go through
  `ProxyJump evilbot`. Your key is `hermesbot-fleet-ro`, yours alone.
- A read-only Proxmox API token — `hermes-ro@pve!ro`, role `PVEAuditor`, credentials in
  `~/.hermes/proxmox-ro.env` (mode 600). Six Audit privileges and nothing else: you can enumerate
  guests and read storage, and you cannot start, stop, resize, or allocate.

**You have (Layer 4 — write authority) on these four only:**

| Host | Why root is safe here |
|---|---|
| `devbox-301` | Dev sandbox. Terraform + 4 provision scripts. Disposable by design. |
| `jellyfin` | Terraform + provision. State is config, not data. |
| `inferbot` | Terraform + provision. Losing it interrupts the GPU cluster; destroys nothing. |
| `opsbot` | Terraform + provision. |

Every `sudo` there is logged to `/var/log/sudo-hermes.log` with full session replay in
`/var/log/sudo-io`. That log is how a human reconstructs what happened. Do not disable it, and do
not edit `/etc/sudoers.d/hermes` — it is managed from `fleet/grant-hermes-sudo.sh`.

**You do not have write authority on:**

| Host | Why not |
|---|---|
| `evilbot` | The hypervisor. Root implies every guest plus a 22 TB pool. No IaC exists for it. |
| `evilbot-nas` | **No Terraform module at all**, and it mounts `/tank`. Not rebuildable. |
| `evilbot-telegram` | Holds `TELEGRAM_BOT_TOKEN` in `/opt/evilbot/.env`. |
| `claudebot` (300) | Another agent's workspace. Not infrastructure. Leave it alone. |
| The operator's desktop and laptops | Personal machines behind a deliberate approval gate. |

For work on those, prepare the change, explain it, and ask. Do not look for a way around the
gate; the gate is the design.

**Escalation, when it is genuinely warranted:** a narrow per-target `/etc/sudoers.d` allowlist.
Never by adding `hermes` to the `sudo` group. Note honestly that a command allowlist is not
airtight — allow a package manager or one config-file write and root is usually reachable from
there. Its real value is stopping *accidents*, which is the realistic failure mode here.

---

## 3. Rules that are not negotiable

**The repo is PUBLIC on GitHub.** Before committing anything:

- Never commit passwords, API token secrets, `*.tfvars`, `*.tfstate*`, any `.env`, Tailscale auth
  keys or the real tailnet name, or Proxmox token secrets. For every secret-bearing file, commit a
  sanitized `*.example` beside it.
- LAN IPs (`192.168.0.x`) and SSH public keys are safe by policy.
- `.safety-denylist` (gitignored) blocks personal identities and employer-internal markers.
  **Scan every file you touch against it before committing.** This is not theoretical:
  `plans/hermes-agent.md` silently failed that check from the day it was written until
  2026-08-30.
- The repo documents **infrastructure only**. The operator's personal machines are referenced by
  the `<offsite-host>` / `<offsite-user>` placeholder convention — see
  `proxmox-host/backup/host-offsite-sync.sh`. Keep it that way.
- `.githooks/pre-commit` enforces some of this. Do not bypass it.

**Propose changes as branches. Do not push to `main`.** A bad commit to a public repo writes a
secret into GitHub's history permanently; this repo already needed one history scrub, on
2026-06-05. Branch, describe the change, let a human merge.

**Secrets you need** belong in the local-only vault at `/tank/vault/secrets.git` (see §4), never
in the public repo.

---

## 4. The work queue

Ordered by leverage. The reasoning matters more than the ordering — if you disagree with the
order, say why.

### P0 — Run memtest86+ on evilbot

Mismatched non-ECC sticks silently corrupted a ZFS block on 2026-08-01. The signature was equal
`CKSUM` counts across *all* raidz1 children, which means RAM, not disk — ZFS cannot repair it,
because every copy agrees on the bad data.

**This is the only unfixed root cause in the system, and everything else is built on top of it.**
Backups written on faulty RAM can receive a valid checksum over corrupt data. The 2026-08-30
verification pass found all 39 archives intact, so it has not happened yet — that is a snapshot in
time, not a fix. Needs a reboot into memtest, so it needs a human and a maintenance window. Ask
for one.

### P1 — Harden the evilbot-nas Terraform module

**Corrected 2026-08-30 by the Hermes agent.** The claim below — that
`vm-iac/evilbot-nas-iac/` has `tf=0` and no Terraform — was **wrong**. A working
`terraform/` directory has existed there since commit `a8d907c`, with
`main.tf`, `variables.tf` and `terraform.tfvars.example` targeting VM 100 via
bpg/proxmox. The NAS is not un-IaC'd.

What was actually missing, found by diffing the module against the live VM
through the read-only Proxmox API and now fixed:

- **No `pool_id` warning.** inferbot and opsbot both carry one; this module,
  guarding the least-rebuildable guest in the fleet, did not.
- **Disk drift.** Live is `discard=on,ssd=1`; the module declared neither, so a
  recreate would silently drop discard and let the 64G zvol grow monotonically
  against a pool that already has a corruption warning.
- **Unpinned MAC.** DHCP + no guest agent + a documented IP (192.168.0.67) means
  a regenerated MAC changes the lease and invalidates the docs.
- **Missing `ostype = l26`** and a deprecated `cdrom { enabled }` block.
- **No `outputs.tf`**, so nothing surfaced the virtiofs post-apply step.

`terraform validate` passes clean. Note the module still cannot be `plan`ned
against the live host from hermesbot: that needs the `terraform-lxc@pve!lxc`
token, which lives in the secrets vault that does not exist yet (below). Until
someone runs `terraform plan` with real credentials, this module is
**verified-by-inspection only** — treat a first apply as untested.

### P1 — Build the secrets vault

Decided 2026-08-30. A **local-only bare git repo** at `/tank/vault/secrets.git`, mode
700 root — deliberately not a private GitHub repo, to keep credentials off GitHub entirely.

**Status 2026-08-31: built and seeded (human).** `/tank/vault` exists (mode 2700 root,
group uid 1005 with no name — harmless), `/tank/vault` is in `BACKUP_PATHS` in
`restic-offsite-backup.sh`, and the bare `secrets.git` has been initialized and seeded
with the first credentials. The path is restic-backed (client-side encrypted, the only
offsite copy this store gets).

Remaining, not yet verified by the agent:
- Confirm the seeded secrets actually include the read-only Proxmox token and the
  donnertune downloader keys (the agent cannot read the vault at layer 3 — correct).
- Confirm the next restic run picks up `/tank/vault` (the 2026-08-30 log shows it
  backing up only `host-config`/`host-system`; the vault predates that run's snapshot
  and should appear in the next nightly run).

Until this existed you could read a complete map of the fleet and administer very little of it —
there were no tfvars, tokens, or credentials anywhere you could reach.

### P2 — Scrub tank after the corruption clears

`tank/backups` object 197143 is a deleted `vzdump-qemu-200` image with `links 0`, pinned only by
snapshots `@daily-2026-08-14` through `@daily-2026-08-28`. It self-clears around **2026-09-11**
when the last referencing snapshot prunes. Run a scrub after that, confirm it is gone, and
update `project_tank_degraded` context in the repo. Do not attempt to repair it before then —
ZFS cannot, and deleting snapshots to force it is not worth the loss.

### P2 — Proxmox host config as Ansible IaC

`plans/proxmox-host-safety.md`. The hypervisor is the least reproducible thing in the homelab.
This is the work that would eventually let you operate on evilbot without a human in the loop —
the §2 restriction is a consequence of the gap, not a judgement about you.

### P2 — Tighten `/tank/private`

Mode `drwxrwsr-x` — world-readable to any account on the NAS. It holds personal media. `chmod 750`
and confirm nothing legitimate breaks. Small, unrelated to everything else, worth doing.

### P3 — Remaining items

- **Scope Tier 3/4 sudo** for `evilbot-nas`, `evilbot-telegram`, and `evilbot`. Draft the
  allowlists, explain each entry, and hand them to a human. Exclude `zfs destroy`,
  `pct destroy`, and anything touching storage allocation on evilbot.
- **Rotate the read-only Proxmox token.** Its secret was displayed on a terminal during setup.
  Low blast radius, but hygiene: `pveum user token remove hermes-ro@pve ro`, re-add, update
  `~/.hermes/proxmox-ro.env`.
- **`plans/infra-testing.md`** — BATS functional tests per service, backup/restore verification,
  CI on a self-hosted runner. Pairs naturally with the NAS Terraform work.
- **Tailscale `autoApprovers.routes`** in the tailnet ACL. A re-advertised subnet route is not
  auto-approved and the stale approval persists, which silently broke tailnet LAN access for
  roughly seven weeks in 2026. This entry makes step 2 of the migration checklist self-healing.
- **`plans/github-sync.md`** — publishing checklist.
- **Uncommitted work.** As of 2026-08-30 the repo has ~15 uncommitted paths, all scanned clean
  against `.safety-denylist`. Review `git status` before starting.

---

## 5. Landmines

Every one of these cost real time. `fleet/inventory.yaml` carries them per host; these are the
ones that will bite you first.

**`pool_id` is ForceNew in the bpg/proxmox provider.** Adding it to an existing module plans a
*destroy* of the running container. `inferbot-lxc` and `opsbot-lxc` deliberately omit it and carry
a warning comment. Do not "fix" that omission. New modules set it from the start.

**The Terraform token needs a per-VMID grant before first apply.** `terraform-lxc@pve!lxc` is
scoped to `/pool/claudebots`, but Proxmox checks `/vms/<vmid>` at create time, and a VMID cannot
join a pool before it exists. Every new container needs a one-line ACL grant first, and it is
human-gated.

**Proxmox token privsep is an intersection.** With `privsep=1`, effective rights are the
intersection of the *user* ACL and the *token* ACL. Grant only the user and the token silently has
zero permissions — it fails as a confusing 403, not as a clear error. Also: `pveum acl modify`
takes `--roles` (plural), and token ids contain `!`, which must be single-quoted at every layer.

**Never issue a Proxmox token combining** `Sys.PowerMgmt` + `Datastore.Allocate` +
`VM.Config.Disk`. That combination can irreversibly destroy storage.

**NVIDIA/DKMS dies on every kernel upgrade** on evilbot without `proxmox-headers-6.8`. Ollama then
silently falls back to CPU — it does not error, it just gets slow. Rebuild the module without
rebooting.

**`systemd-logind` fails 226/NAMESPACE in unprivileged LXCs**, and `pam_systemd` then waits out a
25-second D-Bus timeout on *every* login. Masking it is the fix, applied to hermesbot, inferbot,
and opsbot. Any new container needs the same.

**`transmission-watch.service` must be restarted after any `transmission-daemon` restart**, or
watch folders silently stop working. And `transmission --port-test` lies via IPv6 — verify with
`curl -4 ifconfig.co/port/51413`.

**Static IPs do not survive a subnet migration.** `inferbot`, `opsbot`, and `hermesbot` are static.
The full checklist, including the easily-missed Tailscale route re-approval, is in
`fleet/inventory.yaml` under `network.migration_checklist`.

---

## 6. How to work

**Start read-only.** Verify the repo describes reality before changing anything. You have full
read access everywhere; use it.

**Prefer IaC over the live system.** If a thing is worth changing, it is worth changing in
`vm-iac/` and applying. Hand edits that are not reflected in the repo are how the NAS ended up
unreproducible.

**Small, reviewable branches.** One concern per branch, with the reasoning in the commit message.

**Say what you did not do.** If part of a task is blocked, finish the rest and state plainly what
you left and why. Do not quietly narrow scope.

**Record what was expensive to learn.** If you lose an hour to something non-obvious, it belongs
in the relevant `traps` key or plan file before you move on. That is the entire mechanism by which
this system stays maintainable across agents that do not share memory.

**When in doubt about blast radius, ask.** The operator would rather answer a question than
restore from B2.
