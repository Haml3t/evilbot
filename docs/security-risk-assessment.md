# Residual-Risk Assessment — Public `evilbot` Repo

**Scope:** Everything tracked in git and published at the public GitHub repo. This assessment
covers what *remains* after the earlier history scrub (real personal names → generic, personal
folder name genericized, tailnet name → `<tailnet>`, author metadata normalized, stray `.venv/`
removed, `.gitignore` hardened to `**/*.tfvars` / `**/*.tfstate*`, employer-internal docs
gitignored). Live secrets (Proxmox API token in a tfvars, passwords in a tfstate) were verified
to have **never** been committed.

**Date:** 2026-06-05 · **Reviewer role:** security reviewer · **Repo state:** 65 tracked files,
already scrubbed and force-pushed.

---

## Executive Summary

**Verdict: the published repo is low-risk and safe to keep public as-is.** Nothing tracked
exposes a credential, a private key, an externally-routable address, or an
internet-reachable service. The residual disclosures are architectural metadata (LAN IPs,
hostnames, vmids, ports, software versions, usernames) that are useful to an attacker *only
after* they already have a foothold on the LAN or in the Tailnet — at which point this repo
saves them a few minutes of `nmap`, nothing more. The scrub did its job.

The one thing that genuinely matters here is **not in the public repo yet**: the local working
tree contains **untracked** files staged for a future commit that *do* re-introduce sensitive
identifiers (a real personal first name, a real second-machine hostname, and a new host IP).
Those must be scrubbed before the next `git add`/push.

**Top 3 recommendations:**

1. **Before the next push, scrub the untracked working-tree additions** (`inference/`,
   `docs/proxmox-host-backup-recovery.md`, `proxmox-host/backup/host-offsite-sync.sh`,
   `inference/vram-reporter/install.sh`, the inference proxy config). They contain a real
   personal first name, a real desktop hostname, and a host IP that the prior scrub explicitly
   removed elsewhere. Run the `.safety-denylist` scan (the template is already in the tree) as a
   pre-commit gate. **This is the only High-priority item, and it is preventative, not a current leak.**
2. **Keep the 192.168.0.x LAN IPs as-is.** Templating them adds zero security value and
   degrades the portfolio's readability (see the dedicated verdict below). Do **not** spend
   effort on this.
3. **Remove the password-reset recipe and salt/hash format string from `docs/jellyfin.md`,**
   and template the `IMAGEGEN_URL` / Tailscale references. These are the only tracked items
   that meaningfully reduce an attacker's work; both are cheap to fix.

---

## Headline Question: Are the 192.168.0.x LAN IPs a real risk? Should they be templated/removed?

**Verdict: No, they are not a real risk. Keep them as-is. Do not template or remove them.**

Reasoning, concretely:

- **They are RFC1918 (`192.168.0.0/16`).** They are not routable from the public internet.
  An external attacker cannot send a packet to `192.168.0.145` from outside the network. The
  address is meaningless to them.
- **They leak only that the network uses the single most common default consumer subnet
  on earth.** `192.168.0.0/24` with the gateway at `.1` is the factory default of a large
  fraction of home routers. Disclosing it tells an attacker essentially nothing they wouldn't
  assume by default.
- **For the only attacker who *can* reach these addresses — one already on the LAN or in the
  Tailnet — the IPs provide no privilege.** Someone with a LAN foothold runs `arp -a` or
  `nmap -sn 192.168.0.0/24` and learns every live host, open port, and service banner in
  under a second. The repo's value to that attacker (a tidy inventory of 5 hosts) is a rounding
  error against what they already have. Disclosure does not change their capability.
- **Templating actively hurts.** This is a portfolio repo whose *point* is to show real,
  legible homelab architecture. Replacing every IP with `<proxmox-host-ip>` makes the docs
  harder to read and reuse, for no defensive gain — security through obscurity that obscures
  nothing, because the subnet is a default and the hosts are unreachable externally anyway.

The repo's own `CLAUDE.md` already states this policy correctly ("LAN IPs — RFC1918, not
routable from the internet — Safe to commit as-is"). That judgment is sound; this assessment
endorses it.

**One nuance, not a reversal:** IPs become slightly more sensitive *only* if paired with a
credential or an externally-exposed service. None of that is present in the tracked tree. So the
verdict holds unconditionally for the current repo.

---

## Disclosure Inventory & Threat Model

Threat actors referenced below:

- **EXT** — external internet attacker (no LAN/Tailnet access).
- **LAN** — attacker who already has a foothold on the home LAN.
- **DEP** — malicious dependency / supply-chain code running *inside* a container.
- **TS** — attacker who has compromised the Tailscale account/node.

| # | Disclosed item | Where | What it reveals | Realistic threat | Severity | Recommendation |
|---|---|---|---|---|---|---|
| 1 | **LAN/RFC1918 IPs** (`192.168.0.145`, `.67`, `.222`, `.239`, `.196`, gateway `.1`) | CLAUDE.md, all docs, IaC, scripts | The default home subnet + per-host addresses | EXT: none (unroutable). LAN: trivially self-discoverable. | **Low** | **Keep as-is.** See verdict above. |
| 2 | **SSH *public* key** (`ssh-ed25519 …claudebot-to-evilbot`) | CLAUDE.md, plans/jellyfin.md | A public key. Public keys are designed to be shared. | None. A public key cannot be used to authenticate *as* the holder; it only lets others verify the holder. No private-key exposure. | **Low** | **Keep as-is.** Standard and safe. |
| 3 | **Full network topology + vmids** (host + 4 guests, vmid 100/200/300/400, roles, OS, jump-host chain) | CLAUDE.md table, plans, docs | Complete inventory: what runs where, which is the jump host, which lacks a guest agent | EXT: none. LAN/TS: saves recon time only; confers no access. The jump-host design is itself a sound control. | **Low** | **Keep as-is.** Good portfolio content; no privilege leak. |
| 4 | **Software & version strings** (Jellyfin 10.11.8, python-telegram-bot 22.5, httpx 0.28.1, Node 22, Debian 12, Ubuntu 24.04, bpg/proxmox ~0.73, Terraform 1.6.6) | docs, requirements, IaC | Exact versions → an attacker can look up known CVEs for those versions | EXT: none (services not exposed). LAN/TS: could match a version to a public CVE *if* a service is reachable. Versions drift; this is a snapshot. | **Low–Med** | **Keep, but treat as a patching reminder.** Don't hide versions; instead keep the software patched. Pinned versions in a public portfolio are normal and expected. |
| 5 | **Service ports** (Jellyfin 8096/8920, Transmission RPC 9091, image-gen 5005, Proxmox 8006) | docs, plans, IaC | Which ports host which service | EXT: none unless port-forwarded (no evidence of that). LAN: self-discoverable by scan. | **Low** | **Keep as-is.** |
| 6 | **Transmission RPC whitelist** (`127.0.0.1`, `192.168.*.*`, `10.*.*.*`, `100.*.*.*`) | docs/evilbot-nas.md | RPC trusts the whole LAN and the whole Tailnet CGNAT range | LAN/TS: confirms that *any* host on LAN or Tailnet can hit the RPC (auth still required). This is a real, if mild, design weakness it advertises. | **Low–Med** | **Optional hardening (operational, not a repo edit):** tighten the whitelist. Documenting it publicly is fine; the looseness is the (minor) issue, not the disclosure. |
| 7 | **Internal absolute paths** (`/opt/evilbot/.env`, `/etc/transmission-remote.env`, `/root/.secrets/…`, `/tank/…`, `/etc/pve/firewall/`) | throughout | Exactly where secrets live on each box | DEP/LAN/TS *with* shell access: tells them which files to grab. Without a foothold: useless. | **Low** | **Keep as-is.** Path disclosure only matters post-compromise; the secrets themselves are correctly absent. |
| 8 | **Firewall rule contents** (`300-claudebot.fw`: OUT ACCEPT tcp/22 to `.145`, OUT DROP tcp/22 else) | proxmox-host/firewall/ | The exact egress-SSH containment policy for the AI sandbox | LAN/TS: reveals the boundary so they know what to bypass — but the rule is enforced at the hypervisor, not the container, so knowing it doesn't help bypass it. Publishing a *good* control is fine. | **Low** | **Keep as-is.** This is a security *strength* to showcase, not a leak. |
| 9 | **Usernames & group names** (`admin`, `user2`, `mediaadmin`, `mediauser`, `evilbot`, `jellyfin`, `ubuntu`, `terraform-ro@pve`, `terraform-lxc@pve`, `mediagroup`, etc.) | docs, IaC, ansible | Valid login/account names → removes the username-guessing half of a brute force | LAN/TS *with* a reachable SSH/Samba/RPC service: marginally easier credential attack. Passwords/keys still required. `user2` is already a scrubbed generic. | **Low–Med** | **Keep as-is** (generic names already), **but ensure key-only SSH + strong Samba/RPC passwords.** The mitigation is auth strength, not name secrecy. |
| 10 | **`<tailnet>` placeholder + Tailscale references** | CLAUDE.md, docs (nas, telegram), plans | That a Tailnet exists and is used to reach a backend; the real tailnet name is correctly redacted | TS: an account compromise is the prerequisite, and that compromise doesn't come *from* this repo. The placeholder leaks nothing. | **Low** | **Keep `<tailnet>` placeholder.** Correctly scrubbed. |
| 11 | **ComfyUI / image-gen endpoint** (`IMAGEGEN_URL/image`, `/output/<file>`, port 5005, "ComfyUI HTTP wrapper … over Tailscale") | docs/evilbot-telegram.md, telegram-bot/example.env, evilbot-telegram/provision.sh | A ComfyUI backend exists, its API shape, and that it's Tailnet-reachable on :5005 | TS only (Tailnet-internal). API shape disclosure is low value without reachability. The example.env already uses `<imagegen-tailscale-ip>`. | **Low** | **Keep, lightly templated.** Already uses placeholders for the IP — good. No change needed. |
| 12 | **`*.example` files** (tfvars.example, devbox-secrets.env.example, restic-b2.env.example, repos.txt.example, CLAUDE.md.template.example, terraform.tfvars.example ×5) | vm-iac/, proxmox-host/backup/ | Token *format* (`user@realm!tokenid=secret`), env var *names*, secret *structure* — all with placeholder values | None directly. They teach an attacker the shape of secrets, not the secrets. This is exactly what `.example` files are for. | **Low** | **Keep as-is.** Verified: all hold placeholders (`<token-secret>`, `your-…-here`, `<base64-encoded-private-key>`, `CHANGEME`), no real values. |
| 13 | **Jellyfin password-reset recipe** (full PBKDF2-SHA512 salt/hash format string + the exact SQL `UPDATE Users SET Password=…` against `jellyfin.db`) | docs/jellyfin.md | A copy-paste method to forge a Jellyfin admin credential given filesystem access | LAN/TS/DEP *with* shell on the Jellyfin box: a ready-made privilege step. Not novel (it's a known technique), but it's spelled out. | **Med** | **Trim it.** Replace the literal hash-format string + SQL with a one-line pointer ("reset via SQLite — see Jellyfin docs"). Cheap, removes a turnkey escalation snippet. |
| 14 | **Jellyfin DHCP MAC address** (`BC:24:11:65:5E:40`) | docs/jellyfin.md | A specific NIC MAC | LAN: enables ARP-spoof targeting / DHCP-reservation impersonation of that host. Low value; MAC is observable on-LAN anyway. | **Low** | **Optional:** template as `<jellyfin-mac>`. Minor; not urgent. |
| 15 | **Provision default secret `RPC_PASS=CHANGEME`** (in `evilbot-nas-iac/provision.sh` heredoc) | vm-iac/evilbot-nas-iac/provision.sh | A default placeholder password baked into the provisioning flow | If an operator forgets to change it, the NAS ships with a known RPC password. The script *does* print a warning to change it. | **Low–Med** | **Keep but strengthen the flow:** make the script refuse to start the service while `RPC_PASS=CHANGEME`, rather than only warning. Documentation is fine; the weak default is the (minor) issue. |
| 16 | **GitHub repo/owner + self-hosted runner plan** (`github.com/Haml3t/evilbot`, plan to run a self-hosted Actions runner on claudebot) | plans/infra-testing.md | Repo identity (already public) + that CI would execute on an internal box | DEP: a self-hosted runner on an internal container is a real supply-chain consideration (PR-triggered code execution inside the LAN) — but it's a *plan*, not built. | **Low (now)** | **Keep, but note for implementation:** when building the runner, restrict it to `push`/trusted events, never untrusted-fork PRs. Future-state caution, not a current leak. |

---

## NOT in the public repo yet — scrub before next commit (the only High-priority item)

The local working tree contains **untracked** files that are *not* part of the public repo but
are clearly staged for a future commit. Several re-introduce identifiers the earlier scrub
deliberately removed. **These are not currently leaked** — they are local-only — but they will
leak the moment someone runs `git add . && git push` without scrubbing.

| Untracked path | Sensitive content | Action before committing |
|---|---|---|
| `proxmox-host/backup/host-offsite-sync.sh` | Real personal first name as a username, a real second-machine hostname, and host IP `192.168.0.12` | Replace name → generic user, hostname → `<offsite-host>`, keep IP (LAN, fine) |
| `docs/proxmox-host-backup-recovery.md` | Same real name (`<user>@<host>:/backups/…`) and hostname repeated throughout | Genericize name + hostname |
| `proxmox-host/backup/cron-entries.txt` (modified) | Adds an off-host-sync line naming the real desktop hostname | Genericize hostname |
| `inference/` (whole tree: proxy, nomad jobs, vram-reporter) | Real first name as SSH user, the second-machine hostname, IP `192.168.0.12`, ComfyUI/Ollama topology across two GPU nodes | Genericize name + hostname before publishing; review `models.yaml` for any embedded URLs |
| `vm-iac/inferbot-lxc/`, `proxmox-host/firewall/500-inferbot.fw` | New LXC/firewall defs (topology only — low, but review) | Review with the rest; topology-only is fine to keep |

**Gate to add:** the repo already ships `.safety-denylist.example`. Copy it to a local
`.safety-denylist` filled with the real terms (employer name, real first/last name, real tailnet,
the desktop hostname) and run `grep -F -i -f .safety-denylist` over staged changes as a
pre-commit/pre-push check. This is the single most valuable safety improvement available, and
the scaffolding for it is already in the tree.

---

## What was done right (worth keeping)

- Secrets live in untracked env files referenced by *name*, never inlined. `.gitignore` now
  matches `**/*.tfvars` / `**/*.tfstate*` by extension (catching the non-canonical
  `jellyfin.tfvars` / `terraform-301.tfstate` that the old exact-name patterns missed).
- Every secret-bearing config ships a sanitized `*.example` with placeholder values only
  (verified across all 8 example/template files).
- Public-key-only SSH, a hypervisor-enforced egress-SSH firewall on the AI sandbox, and a
  least-privilege Proxmox token policy are documented as *practices* — these are strengths to
  showcase, not liabilities.
- The tailnet name, real personal names, and employer-internal docs are correctly absent from
  the tracked tree (verified: `git grep` over `HEAD` finds no real name and no real tailnet).

---

## Bottom line

The public repo as it stands today is **low residual risk and fine to keep public unchanged.**
Two cheap, optional tracked-file trims (#13 Jellyfin reset recipe, #14 MAC) would tidy the last
sharp edges. The **only** thing that rises above "nice to have" is hygiene on the *next* commit:
scrub the untracked `inference/` + off-host-backup additions before they reach GitHub, using the
denylist scaffolding the repo already provides. And to restate the headline: **the LAN IPs are
not a risk — keep them.**
