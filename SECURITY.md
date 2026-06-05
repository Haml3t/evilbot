# Security Policy

This repository is **public**. It is a homelab Infrastructure-as-Code and
documentation portfolio, so everything here is visible to the world the moment
it is pushed. The rules below keep secrets and private identities out of the
public record. Read this before contributing.

If you only read one thing: **never commit a real secret or a real personal /
employer identity.** When in doubt, leave it out and ask.

---

## What is safe to publish

- **LAN / RFC1918 IPs** (`192.168.1.x`, `10.x`, `172.16–31.x`) — not routable
  from the internet.
- **SSH _public_ keys** — public by design.
- **Config structure, scripts, Terraform/Ansible, and plans** where every
  secret has been replaced by an environment-variable reference or a
  placeholder.
- **Architecture docs and runbooks** that describe *this* homelab (evilbot,
  the NAS, the Telegram VM, Jellyfin, claudebot).
- **`*.example` companion files** with placeholder values (see below).

## Never commit (the denylist)

Anything in this list must stay local-only. Most are already enforced by
[`.gitignore`](.gitignore); the patterns are listed so contributors understand
*why*.

- **Passwords, API tokens, or secrets of any kind** — including Proxmox API
  token secrets, the Transmission RPC password, and the Telegram bot token.
- **Terraform variable & state files:** `**/*.tfvars` and `**/*.tfstate*`
  (state and backups). These often embed live secrets in cleartext. Only
  `**/*.tfvars.example` / `**/*.tfstate.example` are allowed through.
- **Any environment file:** `**/.env` and friends (e.g.
  `devbox-secrets.env`, `restic-b2.env`).
- **Devbox private-context files:** `**/devbox/CLAUDE.md.template` and
  `**/devbox/repos.txt`. These carry employer-internal architecture notes and
  private work-repo names. Only their `*.example` versions are public.
- **Ansible vault plaintext** — commit only the *encrypted* vault file, never
  the decrypted form; never commit the vault password.
- **Tailscale auth keys** and the **real tailnet name** — use `<tailnet>` or
  `<tailscale-ip>` as placeholders.
- **Real personal identities** — real first/last names, personal folder names,
  and personal **or** employer commit-author emails.
- **Any employer-internal content** — internal architecture, service names,
  hostnames, or repo names belonging to a workplace.

> **Why the glob hardening matters.** The `.gitignore` used to list exact
> filenames (`terraform.tfvars`, `terraform.tfstate`). That missed
> differently-named files such as `jellyfin.tfvars` (held a live Proxmox API
> token) and `terraform-301.tfstate` (held passwords), which were therefore
> *not* ignored. The patterns are now extension-based globs
> (`**/*.tfvars`, `**/*.tfstate*`) with `!**/*.example` exceptions so a
> creatively-named secret file can never slip past again.

## The `*.example` companion-file pattern

For every file that holds secrets or private context, commit a sanitized
sibling with the suffix `.example`:

```
vm-iac/jellyfin/terraform.tfvars          # real, GITIGNORED
vm-iac/jellyfin/terraform.tfvars.example  # placeholders, COMMITTED

vm-iac/devbox/repos.txt                    # real, GITIGNORED
vm-iac/devbox/repos.txt.example            # placeholders, COMMITTED

vm-iac/devbox/CLAUDE.md.template           # real, GITIGNORED
vm-iac/devbox/CLAUDE.md.template.example   # placeholders, COMMITTED
```

Rules for the `.example` file:

1. Identical **structure / keys** to the real file, so a contributor can copy
   it and fill in the blanks.
2. **No real values** — use obvious placeholders (`<proxmox-api-token>`,
   `changeme`, `your-tailnet-name.ts.net`).
3. The `.gitignore` allow-list (`!**/*.tfvars.example`, etc.) keeps the
   `.example` tracked while the real file stays ignored.

To use one locally: `cp foo.example foo`, then edit `foo` with real values.
`foo` is gitignored and stays on your machine.

## Pre-commit / pre-push scanning

Before every commit and push, run the scans in
[`docs/publishing-checklist.md`](docs/publishing-checklist.md). They grep the
**staged diff** for secret patterns and for the sensitive terms in your local
`.safety-denylist` (a gitignored file; see `.safety-denylist.example` for the
template). `.gitignore` is a safety net, not a substitute for looking at what
you are about to publish.

## Reporting a problem

If you find a leaked secret, a real identity, or any employer-internal content
in this repository or its history:

1. **Do not** open a public issue or PR that quotes the leaked value — that
   only republishes it.
2. Email the maintainer at the address listed on the GitHub profile for
   [@Haml3t](https://github.com/Haml3t), or open a GitHub
   [security advisory](https://github.com/Haml3t/evilbot/security/advisories/new)
   (private).
3. If the leaked item is a live credential, **rotate it immediately** (see the
   runbook in `docs/publishing-checklist.md`) — assume it is compromised the
   moment it touches a public repo.

Treat any secret that has ever been pushed to a public remote as **burned**:
rotate first, scrub history second.
