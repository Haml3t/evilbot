# Tier 3/4 sudo allowlists — draft for human review

Status: DRAFT, not applied. Written 2026-08-31 by the Hermes agent. Nothing here
is installed anywhere; a human must read, edit, and apply.

## What this is

`fleet/grant-hermes-sudo.sh` grants full `NOPASSWD: ALL` to the `hermes` account
on the four rebuildable hosts (Tier 1/2). The three hosts below are deliberately
excluded because a mistake there is NOT a rebuild — it is an outage or a secret
leak. This doc drafts scoped per-target allowlists for them, per §2 of the
handoff: "narrow per-target /etc/sudoers.d allowlist. Never by adding `hermes`
to the `sudo` group."

## The honest caveat first

A command allowlist is **not airtight**. Grant a package manager, a config-file
write, or `systemctl daemon-reload` and root is usually reachable from there.
The real value of an allowlist is stopping *accidents* — a mis-typed `pct
destroy`, a wildcard that eats a dataset — which is the realistic failure mode.
Anyone treating this as a security boundary is wrong. It is a guardrail.

Consequences this design accepts:
- Every grant below carries the same `log_input/log_output` + `logfile` Defaults
  as Tier 1/2, so a human can reconstruct what happened (§2 is explicit that this
  audit trail must never be disabled).
- Nothing below grants a shell, a package manager, or a file write outside a
  named config path.

## Per-host allowlists

### evilbot-nas (Tier 3) — Transmission + Samba + NFS, mounts /tank

The only services Hermes administers here are Transmission and its watch-folders.
The load-bearing trap: `transmission-watch.service` MUST be restarted after any
`transmission-daemon` restart, or watch folders silently stop working. That is
exactly the kind of routine maintenance an agent should be able to do without
waking a human.

```
# /etc/sudoers.d/hermes — evilbot-nas scoped allowlist
Defaults:hermes !requiretty
Defaults:hermes logfile=/var/log/sudo-hermes.log
Defaults:hermes log_input, log_output
Defaults:hermes iolog_dir=/var/log/sudo-io/%{user}
Defaults:hermes iolog_file=%{seq}

# Transmission lifecycle (the watch-service trap makes this the core need)
hermes ALL=(root) NOPASSWD: /usr/bin/systemctl restart transmission-daemon
hermes ALL=(root) NOPASSWD: /usr/bin/systemctl restart transmission-watch
hermes ALL=(root) NOPASSWD: /usr/bin/systemctl status transmission-daemon
hermes ALL=(root) NOPASSWD: /usr/bin/systemctl status transmission-watch
hermes ALL=(root) NOPASSWD: /usr/bin/systemctl daemon-reload

# Read-only diagnosis of the two services
hermes ALL=(root) NOPASSWD: /usr/bin/journalctl -u transmission-daemon*
hermes ALL=(root) NOPASSWD: /usr/bin/journalctl -u transmission-watch*
```

Rationale, entry by entry:
- `restart transmission-*` + `status` + `daemon-reload`: the trap is the entire
  justification. Restarting the daemon without restarting the watch service is
  a silent outage; Hermes must be able to do both as a unit.
- `journalctl -u transmission-*`: read the two services' logs to confirm the
  restart took and to diagnose watch-folder silence.

Explicitly NOT granted on evilbot-nas:
- `/etc/transmission-remote.env` (RPC password) — never readable by Hermes.
- Any file write, `apt`, or `transmission-daemon --dump-settings` to a redirect.
- `samba`/`nfs` management — not needed yet; add only when a real task demands it.

### evilbot-telegram (Tier 4) — holds TELEGRAM_BOT_TOKEN

The entire reason this host is Tier 4 is that `/opt/evilbot/.env` holds the bot
token. So the allowlist is the smallest of the three: restart the bot service
and read its logs, and nothing that could touch the .env.

```
# /etc/sudoers.d/hermes — evilbot-telegram scoped allowlist
Defaults:hermes !requiretty
Defaults:hermes logfile=/var/log/sudo-hermes.log
Defaults:hermes log_input, log_output
Defaults:hermes iolog_dir=/var/log/sudo-io/%{user}
Defaults:hermes iolog_file=%{seq}

# Bot service lifecycle + logs. Service name is a placeholder until the unit
# name is confirmed on the VM (see open question below).
hermes ALL=(root) NOPASSWD: /usr/bin/systemctl restart evilbot-bot
hermes ALL=(root) NOPASSWD: /usr/bin/systemctl status evilbot-bot
hermes ALL=(root) NOPASSWD: /usr/bin/journalctl -u evilbot-bot*
```

Explicitly NOT granted:
- Nothing that can read, copy, or write `/opt/evilbot/.env`. No shell, no `cat`
  allowlisted, no package manager. The token never becomes reachable to Hermes.

Open question: the actual systemd unit name on the VM is unverified. The
`evilbot-bot` placeholder must be replaced with the real name before applying
(`systemctl list-units --type=service | grep -i evilbot`).

### evilbot (Tier 4) — the hypervisor

Root here implies every guest plus the 22 TB pool, and there is no IaC for the
host. The handoff's explicit red line: exclude `zfs destroy`, `pct destroy`,
and anything touching storage allocation.

What Hermes actually needs on evilbot that it cannot already do through the
read-only Proxmox API or read-only SSH:

1. **`zpool status` / `zfs list` error detail.** The read-only account gets
   "List of errors unavailable: permission denied" on `zpool status -v` — the
   exact detail needed to track the RAM-corruption P0. Read-only ZFS inspection
   is safe and high-value.
2. **The NVIDIA/DKMS rebuild.** The trap: every kernel upgrade kills the module,
   and Ollama silently falls back to CPU. Rebuilding requires `dkms install`
   and `update-initramfs`. This is a bounded, idempotent, well-understood action
   that is currently done by hand.

```
# /etc/sudoers.d/hermes — evilbot scoped allowlist
Defaults:hermes !requiretty
Defaults:hermes logfile=/var/log/sudo-hermes.log
Defaults:hermes log_input, log_output
Defaults:hermes iolog_dir=/var/log/sudo-io/%{user}
Defaults:hermes iolog_file=%{seq}

# Read-only ZFS inspection (P0 error detail is otherwise permission-denied)
hermes ALL=(root) NOPASSWD: /usr/sbin/zpool status
hermes ALL=(root) NOPASSWD: /usr/sbin/zpool list
hermes ALL=(root) NOPASSWD: /usr/sbin/zfs list

# NVIDIA/DKMS module rebuild after kernel upgrades (the silent-CPU-fallback trap)
hermes ALL=(root) NOPASSWD: /usr/sbin/dkms status
hermes ALL=(root) NOPASSWD: /usr/sbin/dkms install *
hermes ALL=(root) NOPASSWD: /usr/sbin/update-initramfs -u
```

Explicitly NOT granted on evilbot (the red line, verbatim from the handoff):
- `zfs destroy`, `zpool destroy`, `zpool attach/detach`, `zfs create`, `zfs set`
- `pct destroy`, `qm destroy`, `qm set` (which can reallocate storage)
- `pct create`, `qm create`, anything in the storage-allocation family
- `dkms remove` (build is fine; uninstalling the module is not)

The `dkms install *` wildcard is the one entry here that most needs a human's
eye: it lets a `dkms install` be run for any module. If that is too broad,
tighten it to the specific NVIDIA module (`dkms install nvidia/<version>`), at
the cost of breaking on every version bump.

## What applying looks like

The `grant-hermes-sudo.sh` pattern already exists and is battle-tested (visudo
validation + full-tree re-validation + rollback). The natural next step is a
sibling script, `fleet/grant-hermes-sudo-tier34.sh`, that ships each fragment
above to its host, validates, and rolls back on failure — mirroring the Tier 1/2
script. That script is NOT written here; this doc is the review artifact to
agree the allowlists first.

## Open questions for the human

1. evilbot-telegram: confirm the real service unit name.
2. evilbot: is `dkms install *` acceptable, or should it be pinned to the NVIDIA
   module version?
3. Should `zpool status -v` (the verbose flag) be an explicit separate entry, or
   does the plain `zpool status` entry cover it? sudoers matches the command +
   args literally, so `-v` needs to be spelled out if the human wants the error
   detail specifically.
