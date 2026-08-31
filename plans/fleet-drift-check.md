# Fleet drift check — design

Status: proposed, not built. Written 2026-08-30 by the Hermes agent.

## Why

The existing host monitoring (`proxmox-host/monitoring/`) answers "is the fleet
up and healthy": guest running, systemd unit not failed, ZFS ONLINE, drives
wear-free. It is blind to *intent drift*.

The image-api regression proved the gap. For roughly ten weeks the image-api on
evilbot pointed at the dead pre-migration subnet (`192.168.1.12:8288`). Every
existing check stayed green the whole time: the guest was up, no unit was failed,
ZFS was fine, and `/image` returned HTTP 200 — with the generation silently
falling back to the local CPU/3070 path. The failure was not a crash; it was a
difference between what the live config said and what the repo says should be
true. That difference is exactly what `fleet/inventory.yaml`'s per-host `traps`
exist to encode, and nothing currently compares reality against them.

This doc designs that comparison. It is the missing second half of the handoff's
"verify the repo describes reality before changing anything" — made continuous.

## What it checks: invariants

A drift check must compare *invariants*, not *state*. Naively diffing a live host
against inventory.yaml fires constantly on benign deltas (uptime, free RAM/VRAM,
DHCP lease jitter, queue depth). The invariants are the small set of facts that
should hold unless a human deliberately changed them — most already written down
as `traps`. Candidates, keyed by host:

- **Static IPs** — inferbot `.223`, opsbot `.224`, hermesbot `.225` still match
  `inventory.yaml`. (A subnet migration is the classic silent breaker.)
- **evilbot-nas** — MAC still `BC:24:11:54:3C:26`; `virtiofs0 dirid=tankshare`
  still present on VM 100; the documented `.67` lease still resolves to that MAC.
- **image-api (evilbot)** — `PRIMARY_COMFYUI_URL` points at the *current*
  gpu-desktop address, not the pre-migration `192.168.1.0/24` subnet. The
  ten-week bug is the canonical invariant: a value that was correct in the past
  and wrong now.
- **GPU** — `nvidia-smi` reports the expected card (3070 on evilbot, 3090 on
  gpu-desktop), and the DKMS module is loaded (the "silent CPU fallback" trap).
- **ZFS** — pool ONLINE and no equal-CKSUM-across-all-raidz1-children signature
  (the RAM fault; currently present, so this one should alert until P0 is fixed).
- **logind mask** — still masked on inferbot/opsbot/hermesbot (un-masking
  re-introduces the 25s login stall silently).
- **transmission** — `transmission-watch.service` active after any daemon
  restart (the watch-folders-silently-stop trap).

Each invariant has a *source* (the repo) and a *probe* (a read-only command over
SSH or the Proxmox API). The check emits only deltas from the recorded source.

## The delivery constraint (the real design problem)

The existing alert path (`notify-telegram.sh`) reads `/etc/zfs-alert.env`,
root-only `0600` on evilbot. The Hermes agent runs as `hermes` (uid 1001) with
no sudo on evilbot (Tier 3/4), so it cannot read that file and cannot invoke the
existing sender. This forces a choice:

**A. Host-side (recommended).** The drift check runs on evilbot as root under a
systemd timer, beside `host-health-check.sh`. It gets `notify-telegram.sh`
natively. Cost: evilbot does not hold the repo, so the *invariants* must be
shipped to it as a small machine-readable file (extracted from inventory.yaml),
plus a sync step to keep that file current when the repo changes.

**B. Agent-side.** A Hermes cron on hermesbot runs the probes (it has read access
everywhere and holds the repo), then delivers the report by SSHing to evilbot and
invoking a root-only "send this text" forced-command. Cost: requires a new
narrow sudo/forced-command grant on evilbot, which §2 currently withholds — and
correctly so, since a "send arbitrary text to the ops channel" primitive is close
to root-equivalent in blast radius.

Recommendation: **A**, because it reuses the exact mechanism the rest of the
monitoring already depends on and adds no new authority. The invariant file is
the one new artifact; keep it generated from inventory.yaml rather than
hand-maintained so the two cannot drift from each other.

## Implementation sketch

1. A `fleet/drift-invariants.yaml` (or a generator script) holding the probe
   definitions — host, invariant, expected value, probe command.
2. A `drift-check.sh` on evilbot that reads the invariant file, runs each probe
   read-only, and reports only mismatches via `notify-telegram.sh`.
3. A sync leg (git pull or scp) that updates the invariant file on evilbot when
   the repo changes.
4. Wire into the existing systemd timer set and the dead-man's switch.

## Not in scope

- Remapping SSH/IP scanning to discover hosts. The repo is the source of intent;
  probes *verify* it, never replace it.
- Replacing the existing host-health / ZFS / SMART checks. This is additive.

## Open questions

- Should the current equal-CKSUM ZFS signature alert until memtest P0 closes, or
  is that noise we already know about? (Leaning: alert once, then suppress until
  a human acknowledges — otherwise it nags daily alongside the existing
  zfs-health-check.)
- Sync direction for the invariant file: pull from a git remote on evilbot, or
  push from hermesbot on repo change? The repo is public, so the invariant file
  is safe to mirror — it contains no secrets.
