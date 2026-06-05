#!/usr/bin/env bash
# bootstrap.sh — runs INSIDE the devbox container at provision time.
# Uploaded and executed by provision.sh; not meant to be run directly.
#
# Expects /root/.env to already exist (injected by provision.sh from evilbot secrets).
# Expects /root/repos.txt to already exist (injected by provision.sh).
set -euo pipefail

LOG="/root/bootstrap.log"
exec > >(tee -a "$LOG") 2>&1
echo "=== devbox bootstrap started at $(date) ==="

# ── Load secrets ─────────────────────────────────────────────────────────────
if [[ ! -f /root/.env ]]; then
  echo "ERROR: /root/.env not found — secrets were not injected. Aborting."
  exit 1
fi
# shellcheck source=/dev/null
source /root/.env

# ── System packages ───────────────────────────────────────────────────────────
echo "--- apt update & install base packages ---"
apt-get update -q
apt-get install -y -q \
  curl wget git ca-certificates gnupg jq \
  build-essential python3 python3-pip python3-venv

# ── Node.js 22 ────────────────────────────────────────────────────────────────
echo "--- Node.js 22 ---"
if ! command -v node &>/dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
fi
node --version

# ── Claude Code CLI ───────────────────────────────────────────────────────────
echo "--- Claude Code CLI ---"
npm install -g @anthropic-ai/claude-code
claude --version

# ── Environment: source .env from .bashrc ────────────────────────────────────
echo "--- Configuring shell environment ---"
if ! grep -q 'source /root/.env' /root/.bashrc; then
  cat >> /root/.bashrc << 'EOF'

# devbox secrets (GitHub SSH key, git identity, etc.)
if [[ -f /root/.env ]]; then
  source /root/.env
fi
EOF
fi

# ── Claude Code: auto-login on first SSH ──────────────────────────────────────
echo "--- Installing Claude Code first-login hook ---"
if ! grep -q 'claude login' /root/.bashrc; then
  cat >> /root/.bashrc << 'EOF'

# Claude Code: prompt for OAuth login on first interactive SSH if not yet authenticated
if [[ $- == *i* ]] && [[ ! -f ~/.claude/.credentials.json ]]; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Claude Code is not logged in. Starting OAuth flow..."
  echo "  Open the URL below in your browser to authenticate."
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  claude login
fi
EOF
fi

# ── Trusted SSH keys (evilbot + any others in .env) ──────────────────────────
echo "--- Adding trusted SSH keys ---"
if [[ -n "${EVILBOT_SSH_PUBKEY:-}" ]]; then
  if ! grep -qF "$EVILBOT_SSH_PUBKEY" /root/.ssh/authorized_keys 2>/dev/null; then
    echo "$EVILBOT_SSH_PUBKEY" >> /root/.ssh/authorized_keys
    echo "  Added evilbot key"
  fi
fi

# ── GitHub SSH key ────────────────────────────────────────────────────────────
echo "--- Installing GitHub SSH key ---"
mkdir -p /root/.ssh
chmod 700 /root/.ssh

if [[ -z "${GITHUB_SSH_KEY_B64:-}" ]]; then
  echo "WARN: GITHUB_SSH_KEY_B64 not set in /root/.env — skipping SSH key setup"
else
  echo "$GITHUB_SSH_KEY_B64" | base64 -d > /root/.ssh/work_id_ed25519
  chmod 600 /root/.ssh/work_id_ed25519

  # SSH config: route github.com through the work key
  if ! grep -q 'work_id_ed25519' /root/.ssh/config 2>/dev/null; then
    cat >> /root/.ssh/config << 'EOF'

Host github.com
  IdentityFile ~/.ssh/work_id_ed25519
  User git
  StrictHostKeyChecking accept-new
EOF
    chmod 600 /root/.ssh/config
  fi

  echo "Testing GitHub SSH auth..."
  ssh -T git@github.com 2>&1 | grep -E 'successfully authenticated|Permission denied' || true
fi

# ── Git global config ─────────────────────────────────────────────────────────
echo "--- Configuring git ---"
git config --global user.name  "${GITHUB_USER:-devbox}"
git config --global user.email "${GITHUB_EMAIL:-devbox@local}"
git config --global init.defaultBranch main

# ── Clone work repos ──────────────────────────────────────────────────────────
echo "--- Cloning work repos ---"
mkdir -p /root/work

if [[ ! -f /root/repos.txt ]]; then
  echo "WARN: /root/repos.txt not found — skipping repo clone"
else
  while IFS= read -r repo || [[ -n "$repo" ]]; do
    # Skip blank lines and comments
    [[ -z "$repo" || "$repo" =~ ^# ]] && continue

    name=$(basename "$repo" .git)
    if [[ -d "/root/work/$name" ]]; then
      echo "  Already exists, skipping: $name"
    else
      echo "  Cloning: $name"
      git -C /root/work clone "$repo" "$name" 2>&1 \
        || echo "  WARN: failed to clone $repo (check SSH key / repo URL)"
    fi
  done < /root/repos.txt
fi

# ── Write CLAUDE.md ──────────────────────────────────────────────────────────
echo "--- Writing /root/CLAUDE.md ---"
if [[ -f /root/CLAUDE.md.template ]]; then
  cp /root/CLAUDE.md.template /root/CLAUDE.md
  echo "  /root/CLAUDE.md written from template"
else
  echo "  WARN: CLAUDE.md.template not found — skipping"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "=== bootstrap complete at $(date) ==="
echo "Work repos: /root/work/"
echo "Claude Code: will prompt for OAuth login on first SSH"
echo "Bootstrap log: $LOG"
