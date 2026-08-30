#!/usr/bin/env bash
# Provision a fresh hermesbot LXC after terraform apply.
# Installs Hermes Agent under a dedicated non-root user.
# Usage: ./provision.sh <container-ip> [repo-path]
# Requires SSH access via the evilbot jump host.
#
# This script deliberately stops short of:
#   - `hermes setup --portal`  (interactive OAuth — run it yourself as the hermes user)
#   - starting the gateway      (do not expose anything before the user allowlist is set)
#   - installing any outbound fleet credentials (Phase 3 — hermesbot gets its OWN
#     keypair and a read-only Proxmox token; never copy claudebot's key here)
set -euo pipefail

CONTAINER_IP="${1:?Usage: $0 <container-ip> [repo-path]}"
REPO_PATH="${2:-/root/evilbot-repo}"
JUMP="root@192.168.0.145"

echo "==> Provisioning hermesbot at $CONTAINER_IP"

ssh -o StrictHostKeyChecking=accept-new -J "$JUMP" "root@$CONTAINER_IP" bash << 'REMOTE'
set -euo pipefail

echo "--- System update ---"
apt-get update -q && apt-get upgrade -y -q
# ripgrep + ffmpeg are Hermes runtime deps; the Playwright/Chromium shared libs
# are the one part of the install path that genuinely needs root, so do it here
# rather than letting the installer degrade to a print-this-command fallback.
apt-get install -y --no-install-recommends \
  curl wget git ca-certificates gnupg ripgrep ffmpeg xz-utils zstd \
  python3 python3-venv python3-pip \
  libnss3 libxkbcommon0 libatk1.0-0 libatk-bridge2.0-0 libcups2 \
  libdrm2 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \
  libgbm1 libpango-1.0-0 libcairo2 libasound2

# Both of the following were MISSING on a stock debian-12-standard container and
# each broke the install in a way that is hard to read from the output (2026-08-29):
#
#   libatomic1      Node 26 links against libatomic.so.1. Without it every `node`
#                   invocation dies with "error while loading shared libraries".
#                   The installer reads that as "Node is unsupported", re-downloads
#                   and re-extracts Node, and finally exits 127 — never once naming
#                   the real problem.
#   build-essential node-pty is a native module and needs a C++ compiler. The
#                   installer tries `apt install build-essential` itself, but the
#                   hermes user has no sudo (deliberately), so it can only warn and
#                   exit 1. Installing it here as root keeps the service account
#                   sudo-less.
apt-get install -y --no-install-recommends libatomic1 build-essential

echo "--- systemd-logind: mask (unprivileged LXC) ---"
# On an unprivileged Proxmox LXC, systemd-logind cannot start:
#   Failed to set up mount namespacing: /run/systemd/unit-root/proc: Permission denied
#   -> status=226/NAMESPACE
# It then dies in a restart loop, and pam_systemd blocks the FULL 25-second D-Bus
# activation timeout on EVERY ssh login and every `su -`. Measured 2026-08-29:
# 25.43s per login before, 0.42s after.
#
# Masking is the honest fix: the service genuinely cannot run here, so let D-Bus
# fail fast instead of gutting logind's sandboxing directives to force it up.
# Nothing here needs logind — the gateway runs as a SYSTEM service, not a user
# service, so no seat/session/linger support is required.
# pam_systemd still logs one cosmetic "failed to create session" line per login.
systemctl mask systemd-logind >/dev/null 2>&1 || true
systemctl stop systemd-logind >/dev/null 2>&1 || true

echo "--- Dedicated non-root service account ---"
# Hermes supports running as an unprivileged user and the upstream container image
# does so by default. No sudo: anything this agent needs on a REMOTE host goes
# through its own scoped credential (Phase 3), not through local root here.
if ! id hermes >/dev/null 2>&1; then
  adduser --disabled-password --gecos "Hermes Agent" hermes
fi
install -d -o hermes -g hermes -m 0750 /home/hermes/.hermes

echo "--- Hermes Agent install (as hermes) ---"
# NOTE: this is curl|bash from the vendor. It is the documented install path.
# If you'd rather pin: clone the repo at a known-good tag and `uv sync` instead —
# upstream exact-pins every dependency (a deliberate response to the Mini
# Shai-Hulud PyPI worm), so a pinned checkout is genuinely reproducible.
su - hermes -c 'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash'

echo "--- Verify ---"
su - hermes -c 'export PATH="$HOME/.local/bin:$PATH"; hermes --version || true; hermes doctor || true'

echo
echo "=== Provisioning complete. Remaining steps are deliberately manual: ==="
echo "  1. ssh in as hermes and run:  hermes setup --portal"
echo "     (OAuth login; sets Nous as provider and enables the Tool Gateway)"
echo "     Choose the 'Blank Slate' preset — everything off except provider/model,"
echo "     File Operations, and Terminal. Opt features back in one at a time."
echo "  2. Confirm a plain CLI conversation works BEFORE configuring any gateway."
echo "  3. Phase 3: generate hermesbot's own keypair, create the read-only"
echo "     Proxmox token, and add a narrow sudoers allowlist on each target."
echo "  4. Phase 4: set terminal.backend=ssh pointed at devbox-301."
echo "  5. Phase 5: NEW BotFather token (do NOT reuse the telegram VM's), set the"
echo "     user allowlist, then install the gateway as a system service."
REMOTE

echo "==> Done."
