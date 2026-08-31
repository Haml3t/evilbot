# Plan: Hermes Agent on evilbot

**Goal:** Evaluate [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) and define how to run it as a persistent, always-on operations agent for the homelab — reachable from Telegram, able to act on the fleet, without handing an LLM root on the Proxmox host.

**Upstream reviewed:** commit `ac6c8028`, v0.20.6, MIT licence, Python 3.11–3.13 + Node 26.

---

## Status

- [x] Phase 0: Decisions — provider = **Nous Portal**; placement = new LXC 700; identity = own keypair
- [x] Phase 1: `hermesbot` LXC (vmid 700) + IaC — **APPLIED 2026-08-29**, CT 700 running at 192.168.0.225
- [x] Phase 2: Install + hosted model provider + CLI smoke test — **DONE 2026-08-30**, model `anthropic/claude-opus-5` via Nous Portal
- [x] Phase 3: Least-privilege fleet identity — **DONE 2026-08-30**: accounts on 7 hosts, own key, client config, read-only `PVEAuditor` token, all verified
- [ ] Phase 3a: Secrets store — decided (local-only bare repo at `/tank/vault/secrets.git`), not built
- [ ] Phase 4: SSH terminal backend → devbox-301 sandbox
- [ ] Phase 5: Telegram gateway (second bot, locked to one user)
- [ ] Phase 6: Homelab skills + cron jobs
- [ ] Phase 7: Firewall, secret hygiene, docs

---

## 1. What Hermes Agent actually is

A self-hosted agent runtime, not a library. The pieces that matter here:

| Subsystem | What it gives us |
|---|---|
| **Messaging gateway** | One process serving Telegram, Discord, Slack, Signal, WhatsApp, Email. `hermes gateway` + a systemd unit (`hermes-gateway`, `Restart=always`, optional `systemd_watchdog_seconds`). |
| **Terminal backends** | `tools/environments/`: `local`, `docker`, **`ssh`**, `singularity`, `modal`, `daytona`, `vercel_sandbox`. The SSH backend uses ControlMaster multiplexing and routes `read_file`/`write_file`/`patch` through the same backend. |
| **Cron** | Durable scheduler (`cron/scheduler.py`), natural-language or cron expressions, per-job model pinning, delivery to any platform, and a **no-agent mode** — a script on a schedule with stdout delivered verbatim and zero LLM calls. |
| **Skills** | Procedural memory as markdown + scripts, agentskills.io-compatible. The agent writes and refines its own. |
| **Memory + session search** | Curated memory files, SQLite FTS5 search across past sessions. |
| **Model providers** | 35+ provider plugins, plus `provider: custom` for **any** OpenAI-compatible `/v1/chat/completions` endpoint. |
| **Delegation** | Subagents for parallel workstreams; `max_spawn_depth`, `subagent_auto_approve` (default false). |
| **Heartbeat / goals** | `/heartbeat every 10m <prompt>` re-enters the *current* session when idle; `/goal` runs a Ralph-style judged loop. |

### Why it fits this homelab specifically

1. **The SSH backend maps onto our existing topology.** We already jump everything through `root@192.168.0.145`. Hermes can drive a remote host as its execution target rather than running commands where the agent process lives.
2. **`inferbot:8000` already speaks the right dialect.** Verified live — the proxy exposes `POST /v1/chat/completions`, `POST /v1/completions`, `/api/models`, `/health`, and health currently reports both nodes `ok` (evilbot 7837/8192 MB free, gpu-desktop 21161/24576 MB free). `provider: custom` + `base_url: http://192.168.0.223:8000/v1` is a one-line integration. See §3 for why that is *not* yet a viable driver model.
3. **Cron + Telegram delivery generalises what we already hand-rolled.** ZED zedlets, the smartd hook and the daily SMART timer all push to Telegram chat `521919699` today. Hermes' no-agent cron mode does the same job with zero LLM cost, and the agent mode adds "explain what changed and why it matters".
4. **Skills are the right home for our tribal knowledge.** The NVIDIA/DKMS kernel trap, restarting `transmission-watch.service` after any `transmission-daemon` restart, the three-step Tailscale route re-approval — these are exactly procedural memory, and they currently live only in `CLAUDE.md` and my memory files.

---

## 2. Placement — new LXC, vmid 700

**Decision: build a dedicated `hermesbot` LXC. Do not reuse an existing container.**

Measured current state:

| Candidate | Verdict |
|---|---|
| **claudebot** (300, 2c/4GB) | **Ruled out by policy.** claudebot is an AI workspace and must never host a daemon other systems depend on. A gateway with `Restart=always` is exactly that. |
| **opsbot** (600, 1c/1GB/7.8GB disk, 41% used) | Too small. It already runs the GitHub Actions self-hosted runner. Hermes' `.[all]` extra pulls Playwright/Chromium and would not fit in 4.5 GB free, let alone leave headroom. |
| **inferbot** (500, 2c/2GB) | **Ruled out by design.** inferbot is deliberately firewalled HTTP-only with no SSH keys. Putting an agent that holds fleet credentials inside it destroys the property that makes it safe to expose. |
| **evilbot host** | Never. The agent must not share a failure domain with the hypervisor. |
| **New LXC 700** | ✅ |

### Sizing and storage

- **4 cores / 8 GB RAM / 40 GB disk.** The gateway plus a browser backend plus a subagent or two is not a 2 GB workload.
- **Put the disk on `local-lvm`** (782 GB available, 6% used). **Not `local`** — it is at 77.5% with only 17 GB free.
- Static IP **192.168.0.225**, gateway `192.168.0.1`, matching the `.223`/`.224` convention.
- ⚠️ Add `.225` to the network-migration checklist in `CLAUDE.md` alongside inferbot and opsbot. Static IPs are the thing that broke in the 2026-06-18 subnet move.

### IaC

`vm-iac/hermesbot-lxc/` following the existing `inferbot-lxc`/`opsbot-lxc` pattern exactly: `main.tf` (bpg/proxmox ~> 0.73, `proxmox_virtual_environment_container`, `unprivileged = true`, `start_on_boot = true`), `variables.tf`, `outputs.tf`, `provision.sh`, `terraform.tfvars.example`. Template `debian-12-standard_12.12-1_amd64.tar.zst` is already cached on the host.

---

## 3. The model problem — read this before anything else

**Hermes hard-rejects any model with under 64,000 tokens of context at startup.** This is documented in `getting-started/quickstart.md` and enforced, not advisory: "Models with smaller windows cannot maintain enough working memory for multi-step tool-calling workflows and will be rejected at startup."

Our current catalog (`inference/proxy/models.yaml`) cannot meet that floor:

| Model | Weights (q4) | KV cache @64k (fp16) | Total | Fits? |
|---|---|---|---|---|
| `llama-3-8b` on evilbot (3070, 8 GB) | ~4.7 GB | ~8 GB | ~12.7 GB | ❌ not close |
| `qwen-32b` on the external 3090 (24 GB) | ~19.9 GB | ~16 GB | ~36 GB | ❌ |

There is a second trap stacked on top: **Ollama silently defaults to a 4,096-token context under 24 GB VRAM**, and context length *cannot* be set through the OpenAI-compatible API — only via `OLLAMA_CONTEXT_LENGTH` on the server or a Modelfile `num_ctx`. Our proxy talks to Ollama over exactly that API, so the proxy cannot fix this on our behalf.

### ⚠️ Claude Pro cannot drive Hermes

Documented explicitly, and listed as the single most common billing surprise:

> **Anthropic — Claude Pro:** ❌ No — Pro subscribers cannot use the OAuth path. … Pro looks like it should work; it doesn't.

The Anthropic OAuth path routes as Claude Code against your account and requires a **Claude Max plan with purchased extra usage credits** — and even then it consumes *only* the extra/overage credits, never the base Max allowance.

This is a trap worth naming: Hermes will happily **auto-detect and read Claude Code's credential store** ("reads Claude Code credential files automatically"). The credential is found locally; the entitlement check fails Anthropic-side. It looks wired up and isn't.

**Working Claude options:** an `ANTHROPIC_API_KEY` (pay-per-token, entirely separate from the Pro subscription), or Claude models via Nous Portal / OpenRouter.

### Recommendation

**Drive Hermes with a hosted API. Leave the GPU cluster doing what it is already good at.**

- Primary: a hosted provider — Nous Portal (`hermes setup --portal`, one subscription also covering web search, image gen, TTS), OpenRouter, or an Anthropic API key. Agentic tool-calling reliability, not raw parameter count, is the limiter, and a 3090 does not close that gap.
- The `aux` model slots (`approval.model`, `mcp.model`) explicitly want a fast/cheap model — those are a reasonable place to route local inference later.
- If a local driver is wanted anyway, the realistic candidate is **Qwen3-30B-A3B-Instruct q4 on the external 3090 workstation with a q8 KV cache** (~18.6 GB weights + ~3 GB KV ≈ 21.6 GB — tight but plausible in 24 GB, and fast at 3B active params). A safer fit is Qwen3-14B q4 (~9 GB + ~5 GB q8 KV), at a real cost in tool-calling quality. Either needs `OLLAMA_CONTEXT_LENGTH=65536` set server-side on that host and a new `models.yaml` entry. **Treat this as a follow-up experiment, not the launch path.**
- Set `cron.model` explicitly. Hermes deliberately **fails closed** on unpinned cron jobs when the global default changes — it skips the run and alerts once — specifically so an unattended job can't silently start billing a new provider.

---

## 4. Security — the part that needs the most care

Hermes' own `SECURITY.md` §2.2 is unusually direct, and we should take it at face value:

> **The only security boundary against an adversarial LLM is the operating system.** Nothing inside the agent process constitutes containment — not the approval gate, not output redaction, not any pattern scanner, not any tool allowlist.

And §2.2 again, on posture:

> Operators running the default local backend with untrusted input surfaces … are operating outside the supported security posture.

An always-on Telegram-facing agent that fetches web pages **is** an untrusted input surface. Combine that with fleet SSH keys and the worst case is an LLM with root on the hypervisor. The following are not optional.

### 4.1 Its own identity — never claudebot's key

Generate a fresh keypair on hermesbot. Do **not** copy `claudebot-to-evilbot`. Distinct keys mean distinct revocation and distinct audit trails.

### 4.2 No root on evilbot

- Create a `hermes` user on each target with a **narrow** `sudoers` allowlist (read-only diagnostics first: `zpool status`, `smartctl -a`, `systemctl status`, `journalctl -u`).
- For Proxmox, use a scoped **API token**, not `ssh root@`. Our own token policy already says start read-only (`VM.Audit`, `Datastore.Audit`) and escalate deliberately — and **never** combine `Sys.PowerMgmt` + `Datastore.Allocate` + `VM.Config.Disk`.
- The agent should be able to *observe* the fleet freely and *change* it only through a gate.

### 4.3 Terminal backend → devbox-301, not localhost

Set `terminal.backend: ssh` pointed at **devbox-301** (vmid 301, already exists as a dev sandbox). Shell and file-tool operations then land in a disposable container instead of on the agent host.

Know the limit, stated plainly in §2.2: this confines shell and file tools **only**. The code-execution tool, MCP subprocesses, plugin loading and skill loading all run in the agent's own Python process and are *not* confined by it. That is the argument for the LXC boundary underneath — hermesbot itself is the real blast-radius wall.

### 4.4 Port the destructive-command guard

We already have `guard-destructive.py` — a PreToolUse hook routing catastrophic commands to human approval, born from the 2026-06-07 audit. Hermes has the analogous surface: `command_allowlist` in `config.yaml`, `tools/approval.py` with per-session state and an optional auxiliary-LLM smart-approval path, and a permanent allowlist.

- Mirror our existing pattern set into `command_allowlist`.
- **Leave `subagent_auto_approve: false`** (the default). Flipping it makes delegated work run dangerous commands with no human in the loop.
- **Never set `HERMES_YOLO_MODE`.** Note it is frozen at import time deliberately, so a skill can't set it mid-process — that is a hint about the threat model they expect.
- Keep `security.*` review on for third-party skills. Their guidance is to read the Python and scripts, not just `SKILL.md`.

### 4.5 Network

- Proxmox firewall on CT 700: egress to the LAN targets it manages, `inferbot:8000`, and the model API. Everything else denied.
- Dashboard binds `127.0.0.1:9119` by default and **stores API keys** — reach it over `ssh -L 9119:localhost:9119`, never `--insecure --host 0.0.0.0`.
- The gateway API server stays off unless `API_SERVER_KEY` is set.
- If we later want it reachable off-LAN, that goes through Tailscale — and see the `CLAUDE.md` note about subnet-route approval, which has bitten us once already.

### 4.6 Telegram

- **Register a second bot with BotFather.** Do not reuse `TELEGRAM_BOT_TOKEN` from `/opt/evilbot/.env` on the telegram VM (200) — one token, one polling consumer.
- Configure the allowed-users allowlist to the single user ID before the gateway is ever exposed. Hermes' hardening guidance calls for a caller allowlist on every network-exposed adapter.

### 4.7 Secret hygiene — the repo is public

`~/.hermes/.env` will hold the provider key and the bot token. Per our rules:

- Commit: `vm-iac/hermesbot-lxc/` (with `terraform.tfvars.example`), `provision.sh`, a sanitized `hermes/config.yaml.example`, and the homelab skills.
- Never commit: `~/.hermes/.env`, `~/.hermes/config.yaml` with real values, `terraform.tfvars`, `terraform.tfstate`, session DBs (they contain conversation content), or the bot token.
- Add `~/.hermes/` patterns to `.gitignore`.
- Run the `repo-safety-check` skill before the first push.
- This is another concrete tenant for the **private companion repo** already on the roadmap — the real `config.yaml` and `.env` belong there.

---

## 5. What it should actually manage

Concrete jobs, ordered by value and by how little damage a wrong answer does.

**Read-only first (weeks 1–2).** Everything below is observation. Build trust before granting mutation.

| Job | Mode | Notes |
|---|---|---|
| Daily fleet health digest | agent cron → Telegram | `zpool status`, SMART, disk %, container states, one paragraph of "what changed since yesterday" |
| ZFS/SMART escalation commentary | agent cron | Our zedlets already alert. Hermes adds interpretation — and it already knows even CKSUM across all vdev children means RAM, not disk |
| `local` storage pressure watch | **no-agent cron** | It is at 77.5%. Zero LLM cost, stdout delivered verbatim |
| Kernel-upgrade / DKMS pre-flight | agent cron | The known trap: driver dies on every kernel upgrade without `proxmox-headers-6.8`, and ollama silently falls back to CPU |
| Backup verification | agent cron | Host config + system tar, off-host target and B2 |
| Tailscale route drift check | agent cron | `tailscale status --json` → `Self.AllowedIPs` must contain the live subnet. This one went undetected for six weeks |

**Then, gated mutation (week 3+).** Restart `transmission-watch.service` after a `transmission-daemon` restart; rebuild DKMS without rebooting; nudge a wedged ComfyUI. Each behind approval, each encoded as a skill.

**Skills to write first** — one per hard-won gotcha, so the knowledge survives outside my memory files:

- `zfs-triage` — degraded pool decision tree, the SATA port/serial map, the "CKSUM across all children ⇒ RAM" rule
- `nvidia-dkms-rebuild` — the kernel-upgrade trap and the rebuild-without-reboot path
- `transmission-watch` — the watch-folder mapping and the mandatory restart ordering
- `tailscale-subnet-route` — all three steps including admin-console approval, which is the one that gets skipped
- `proxmox-safe-ops` — the API token scoping policy and the forbidden permission combination

**Explicitly out of scope:** CI. opsbot's GitHub Actions runner already owns that. Hermes should not grow a parallel build system.

---

## 6. Implementation phases

### Phase 1 — Container ✅ DONE (2026-08-29)
`vm-iac/hermesbot-lxc/` written from the `inferbot-lxc` pattern and `terraform validate`-clean.
4c/8GB/40GB on `local-lvm`, static `192.168.0.225`, unprivileged, `start_on_boot`.

**⚠️ One deviation from the older modules, and it is load-bearing:** `pool_id = "claudebots"`
is set explicitly. The `terraform-lxc@pve!lxc` token was re-scoped on 2026-06-07 from PVEAdmin
on `/` to the custom `ClaudebotLXC` role on `/pool/claudebots`. The `inferbot-lxc` and
`opsbot-lxc` modules predate that change and omit `pool_id` — they only ever worked because the
token was unscoped at the time. A create outside the pool now returns **403**. Do not copy the
omission into new modules.

**Applied 2026-08-29.** CT 700 running, 4c/8GB/40G (37G free), `192.168.0.225`, in pool
`claudebots`, SSH via the evilbot jump host confirmed, egress/DNS OK. Added to the topology
table and the static-IP migration checklist in `CLAUDE.md`.

**The apply first failed 403** — `Permission check failed (/vms/700, VM.Config.Options)`. The
`ClaudebotLXC` role has the privilege; the grant just sits on `/pool/claudebots` while Proxmox
checks `/vms/<vmid>` at create time, and a VMID cannot join a pool before it exists. This had
silently broken container creation for the token since the 2026-06-07 re-scope. Unblocked with a
single-VMID grant (human-approved — `pveum` is Tier-3 gated):

```
ssh root@192.168.0.145 'pveum acl modify /vms/700 -tokens "terraform-lxc@pve!lxc" -role ClaudebotLXC'
```

Note the quoting: the token id contains `!`, which interactive bash history-expands inside double
quotes. Outer single quotes are required. Every future container needs the same one-line grant
before its first apply — see the memory note on IaC token scope.

### Phase 2 — Install ✅ DONE (2026-08-29, updated 2026-08-30)
Vendor installer run as the non-root `hermes` user. Two packages were missing from the base
Debian 12 template and both failed with misleading errors, so `provision.sh` now installs them
explicitly: **`libatomic1`** (Node 26 links against `libatomic.so.1`; without it the installer
misreads the failure as "Node unsupported", re-downloads, and exits 127 without ever naming the
cause) and **`build-essential`** (`node-pty` is a native module needing a C++ compiler; because
`hermes` has no sudo by design, the installer could only warn and exit 1).

`systemd-logind` is masked in `provision.sh` — unprivileged LXCs fail it 226/NAMESPACE and
`pam_systemd` then waits out a 25s D-Bus activation timeout on *every* login. Measured
2026-08-29: **25.43s before, 0.42s after**. The same fix was applied to inferbot and opsbot on
2026-08-30 (0.55s each).

**Setup completed 2026-08-30.** Nous Portal OAuth, Blank Slate preset. Model is
`anthropic/claude-opus-5` via `https://inference-api.nousresearch.com/v1`. `hermes update` run —
the install had been 275 commits behind. Public repo cloned read-only over HTTPS to
`/home/hermes/repo/evilbot`.

### Phase 3 — Identity 🔄 IN PROGRESS
The question this phase answers is *how Hermes learns the fleet* — and the answer is **not** a
network scan. A scan yields IPs and open ports. The repo yields **intent**: why inferbot is
static, why `pool_id` is ForceNew, why equal CKSUM counts mean RAM and not disk. None of that is
discoverable. The curated repo is a better map than anything Hermes could produce itself, so the
repo *is* the substrate and recon is only ever used to verify it.

Four layers, strictly ordered. Each must be trusted before the next is granted:

| Layer | What | Status |
|---|---|---|
| 1. Knowledge | Public repo clone, read-only | ✅ `/home/hermes/repo/evilbot` |
| 2. Inventory | `fleet/inventory.yaml` | ✅ 12 hosts, 19 traps |
| 3. Verification | Own key, unprivileged accounts, read-only Proxmox token | ✅ **COMPLETE 2026-08-30** |
| 4. Action | Per-target sudoers, scoped by rebuildability | ✅ **Tier 1/2 live 2026-08-30**; Tier 3/4 pending |

**Layer 2 — `fleet/inventory.yaml`.** The topology table in `CLAUDE.md` is prose: ideal for an
agent reading context, useless to a cron job that must iterate hosts. The YAML is the
machine-readable source of truth; when the two disagree, the YAML wins. Its per-host `traps` key
is load-bearing — it carries the failure modes that cost real time to discover, so a cron job can
surface them before acting.

**Layer 3 — identity.** hermesbot has its own keypair (`hermesbot-fleet-ro`), generated
2026-08-30 and never shared with claudebot:

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMmhaYs34rDwMm/rcxqLI2/3HFcv9bjo9OJ0H/Mw9qzf hermesbot-fleet-ro
```

The key must land in a **dedicated unprivileged, password-locked, sudo-less `hermes` account** on
each target — *not* in `root`'s `authorized_keys`. Installing it for root on the hypervisor would
hand the agent control of every guest in one step and collapse layers 3 and 4 into each other.
Targets: evilbot plus CTs 301/400/500/600 and VMs 100/200. Excluded: CT 300 (claudebot is a
workspace, not infrastructure) and the operator's personal machines — those are a
separate, explicit decision.

**Provisioned 2026-08-30** on evilbot and CTs 301/400/500/600 and VMs 100/200. All seven verified
reachable from hermesbot via host aliases with `ProxyJump evilbot`; `sudo -n` refused on every one,
and since the password is locked that refusal cannot be satisfied.

Two notes from doing it. The QEMU VMs (100/200) had to be provisioned from claudebot rather than
evilbot: **evilbot's root key is not trusted on its own guests — only claudebot's is.** If
claudebot were lost or rebuilt, those two VMs would be reachable only through the Proxmox console.
That is a real gap in the access model, worth closing independently of this work. Second, the
`hermes` client config lives at `/home/hermes/.ssh/config` on hermesbot and deliberately omits the
personal machines.

**Read-only Proxmox token — done 2026-08-30.** Dedicated `hermes-ro@pve` user, token `ro` with
`privsep=1`, `PVEAuditor` granted on `/`. Under privsep the token's rights are the *intersection*
of the user's ACL and the token's own, so **both** grants are required — with only the user grant
applied the token silently has zero permissions. Credentials at `/home/hermes/.hermes/proxmox-ro.env`
(mode 600, hermes-owned); canonical copy belongs in the vault once it exists.

Verified by reading the effective-permissions API rather than by attempting a destructive call:
the token holds exactly six privileges at every path — `Datastore.Audit`, `Mapping.Audit`,
`Pool.Audit`, `SDN.Audit`, `Sys.Audit`, `VM.Audit` — and nothing else. No `VM.PowerMgmt`, no
`Datastore.Allocate`, no `VM.Config.*`, no `Sys.PowerMgmt`. It enumerates all six containers and
reads storage utilisation; it cannot start, stop, resize, or allocate.

`pveum acl modify` takes `--roles` (plural) on this version, and the token id contains `!`, so it
must be single-quoted at every layer.

**Layer 4 — write authority. Granted 2026-08-30 for Tier 1/2.** Authority tracks
**rebuildability, not trust**: a host that rebuilds from `vm-iac/` in minutes can safely be handed
root, because a mistake there is a rebuild rather than a recovery.

| Tier | Hosts | Grant |
|---|---|---|
| 1 | `devbox-301` | `NOPASSWD: ALL` — dev sandbox, tf + 4 provision scripts |
| 2 | `jellyfin`, `inferbot`, `opsbot` | `NOPASSWD: ALL` — tf + provision, state is config not data |
| 3 | `evilbot-nas`, `evilbot-telegram` | read-only; scoped allowlist pending |
| 4 | `evilbot` | read-only; hypervisor, no IaC, root implies 22TB pool |

Verified: `uid=0(root)` on all four Tier 1/2 hosts, `sudo: a password is required` on all three
Tier 3/4 hosts. `sudo` itself was **absent** from the base template on devbox-301, inferbot and
opsbot and had to be installed.

Audit trail is `/var/log/sudo-hermes.log` plus full I/O replay in `/var/log/sudo-io/`, confirmed
capturing. `rsyslog` is inactive on four of these hosts, so journald and the sudo I/O log are the
*entire* trail — that is why `log_input`/`log_output` are on despite the disk cost.

Never grant by adding `hermes` to the `sudo` group. And note honestly that a command allowlist
(Tier 3/4) is not airtight — allow a package manager or one config write and root is usually
reachable. Its real value is stopping *accidents*, which is the realistic failure mode for an
agent, not a patient adversary.

**`%{seq}` belongs in `iolog_file`, not `iolog_dir`** — sudo expands `%{user}` in a directory but
leaves `%{seq}` literal, creating a directory actually named `%{seq}`. Fixed in the script; re-run
it to clean up.

### Phase 3a — Secrets store (local-only) 🔄 DECIDED, BUILT IN PART

**The gap that blocks real administration: the repo is public, so it holds no secrets.** Hermes
can read a complete map of the fleet and still not administer one machine — no tfvars, no tokens,
no credentials.

**Decision (2026-08-30): a local-only bare git repo, not a private GitHub repo.** It keeps
credentials off GitHub entirely, which removes a whole class of accident that a private repo only
mitigates. Location `/tank/vault/secrets.git`, mode 700 root.

Status as of 2026-08-30 (Hermes agent verification):
- `/tank/vault` EXISTS, mode `2700` root:root-uid-1005 (the "UNKNOWN" group is a nameless uid —
  harmless, but tighten to a real group or leave 700 as the plan says).
- `/tank/vault` is ALREADY in `BACKUP_PATHS` in `restic-offsite-backup.sh` (added with rationale).
- The bare `secrets.git` itself does NOT yet exist. This is the remaining step, plus the first
  commit of real secrets (Proxmox tokens, donnertune keys, /tank/vault API key).

`/tank/private/` was considered and **rejected** — it already exists as a media directory and is
mode `drwxrwsr-x`, world-readable to any account on the NAS. (That permission is worth tightening
on its own merits, unrelated to this.)

`/tank/vault` must be added to `BACKUP_PATHS` in `restic-offsite-backup.sh`. restic encrypts
client-side, so an offsite copy in B2 is safe and is the only durable protection this store gets.
(DONE — the path is already listed.)

The vault stays **root-only for now**. Hermes does not read it at layer 3; the one secret it
needs — the read-only Proxmox token — goes directly into a mode-600 file on hermesbot, with the
canonical copy in the vault.

### Phase 4 — Sandbox backend
`terminal.backend: ssh` → devbox-301. Confirm file tools resolve inside the sandbox, not on hermesbot.

### Phase 5 — Gateway
New BotFather bot. User allowlist. `hermes gateway setup` → system service (headless host, should survive reboot without linger). Set `systemd_watchdog_seconds: 120`. Do **not** add an `ExecStopPost` drop-in — the docs call out that it produces an infinite restart loop and a flood of Telegram messages.

### Phase 6 — Skills and cron
Author the five skills. Add read-only cron jobs. Pin `cron.model`. Run for two weeks before granting any mutation.

### Phase 7 — Harden and document
Proxmox firewall rules. `repo-safety-check`. `docs/hermesbot.md`. Update the topology table in `CLAUDE.md`.

---

## 7. Risks

| Risk | Mitigation |
|---|---|
| **Prompt injection → fleet compromise** | The whole of §4. LXC boundary + SSH backend to a sandbox + no root + scoped API token + allowlist. This is the risk that matters. |
| **64k context floor blocks local models** | Accepted: hosted driver at launch. Local revisit is a tracked experiment (§3). |
| **Hosted API spend runs away unattended** | Pin `cron.model`; use per-job `--reasoning-effort minimal` for cheap jobs; prefer no-agent mode where no reasoning is needed; the fail-closed drift guard is a feature — leave it on. |
| **Secret leak into the public repo** | `.gitignore` + `repo-safety-check` + private companion repo for real values. |
| **Agent duplicates or fights existing automation** | Read-only first. Hermes comments on ZED/smartd alerts; it does not replace them. CI stays on opsbot. |
| **Second Telegram bot confusion** | Separate token, separate bot, distinct name. |
| **Upstream velocity** | Fast-moving repo, exact-pinned deps (a deliberate response to the Mini Shai-Hulud PyPI worm). Pin a known-good version; update deliberately via `hermes update`. |

---

## 8. Open decisions

1. ~~**Model provider**~~ — **DECIDED 2026-08-29: Nous Portal.** One OAuth login covers the model plus the Tool Gateway (web search, image gen, TTS, cloud browser), so the ops skills don't need separate keys. Claude Pro was never an option (§3). Tiering still matters more than the provider: no-agent cron for mechanical checks (zero LLM cost), a cheap model for routine digests via `cron.model`, a strong model only for ad-hoc chat and hard triage.
2. **Static vs DHCP for `.225`** — static matches convention and makes firewall rules stable, at the cost of one more manual step on a network move. Recommend static.
3. **Whether Hermes eventually absorbs the evilbot-telegram bot (vmid 200)** or runs alongside it. Recommend alongside, indefinitely — the existing bot is simple and works.
4. **Does it get the gated personal machines at all?** Recommend no. Those are personal machines behind a deliberate approval gate; an unattended agent should not hold that access.
