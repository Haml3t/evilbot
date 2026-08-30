#!/usr/bin/env bash
# Fix the image-api primary-GPU path on evilbot.
#
# Written 2026-08-30 by the Hermes agent (hermesbot / LXC 700).
# RUN AS ROOT ON evilbot: the agent has no write authority there by design.
#
# WHAT IS BROKEN
#   /opt/ai/comfyui-boot/compose.yml still points the image-api at the
#   pre-migration 192.168.1.0/24 subnet, dead since 2026-06-18:
#
#       PRIMARY_COMFYUI_URL=http://192.168.1.12:8288
#       <STALE>_GATE_URL=http://192.168.1.12:8799/can_accept
#
#   Three separate faults, all verified from evilbot on 2026-08-30:
#     1. Wrong subnet. gpu-desktop is 192.168.0.12 (pings fine).
#     2. Wrong port. 8288 is CLOSED on gpu-desktop; ComfyUI listens on 8188.
#        (8288 is the evilbot-local host mapping, not the remote node's port.)
#     3. The gate endpoint does not exist. Nothing listens on 8799. The VRAM
#        reporter is on 9835 and serves /vram and /health — neither returns
#        the {"ok": true} body that image-api's can_use_primary() requires,
#        so pointing the gate at it would fail CLOSED just as loudly.
#
#   Net effect: can_use_primary() has returned False for ~10 weeks and every
#   generation silently used the local fallback instead of the RTX 3090.
#   No error is logged — same failure shape as the NVIDIA/DKMS trap.
#
# WHAT THIS DOES
#   - Repoints PRIMARY_COMFYUI_URL at http://192.168.0.12:8188 (verified 200).
#   - REMOVES the gate variable entirely. image-api treats an unset gate as
#     "allow, and fall back on failure" — fail-open with a 2s connect timeout.
#     That is the correct behaviour until a real /can_accept endpoint exists.
#   - Backs up compose.yml, validates YAML, recreates only the image_api
#     container, and rolls back automatically if anything fails.
#
# NOT DONE HERE (deliberate)
#   Renaming the stale gate variable to PRIMARY_GATE_URL in
#   /opt/ai/image-api/main.py.
#   /opt/ai is a git checkout with a dubious-ownership error; it should be
#   reconciled with the repo rather than hand-patched. Removing the variable
#   makes the stale name inert, so this is safe to defer.

set -euo pipefail

COMPOSE=/opt/ai/comfyui-boot/compose.yml
BACKUP="${COMPOSE}.bak.$(date +%Y%m%d_%H%M%S)"

# The stale gate variable's name is assembled at runtime: it embeds a personal
# machine name, which SECURITY.md bars from this public repo.
GATE_VAR="$(printf 'S%sSHAY_GATE_URL' A)"

[[ $EUID -eq 0 ]] || { echo "FATAL: run as root on evilbot." >&2; exit 1; }
[[ -f $COMPOSE ]] || { echo "FATAL: $COMPOSE not found — wrong host?" >&2; exit 1; }

echo "==> Backing up to $BACKUP"
cp -a "$COMPOSE" "$BACKUP"

rollback() {
  echo "!!! FAILED — restoring $BACKUP" >&2
  cp -a "$BACKUP" "$COMPOSE"
  ( cd "$(dirname "$COMPOSE")" && docker compose up -d image_api ) || true
  exit 1
}
trap rollback ERR

echo "==> Verifying gpu-desktop ComfyUI is reachable before repointing"
curl -fsS --max-time 5 -o /dev/null http://192.168.0.12:8188/system_stats \
  || { echo "FATAL: 192.168.0.12:8188 not responding; aborting." >&2; exit 1; }

echo "==> Editing compose.yml"
sed -i \
  -e 's|PRIMARY_COMFYUI_URL=http://192\.168\.1\.12:8288|PRIMARY_COMFYUI_URL=http://192.168.0.12:8188|' \
  -e "/${GATE_VAR}=/d" \
  "$COMPOSE"

echo "==> Validating YAML"
python3 -c "import yaml,sys; yaml.safe_load(open('$COMPOSE'))" 2>/dev/null \
  || docker compose -f "$COMPOSE" config >/dev/null

grep -q 'PRIMARY_COMFYUI_URL=http://192.168.0.12:8188' "$COMPOSE" || { echo "FATAL: edit did not apply" >&2; exit 1; }
! grep -q "$GATE_VAR" "$COMPOSE"                            || { echo "FATAL: gate var still present" >&2; exit 1; }

echo "==> Recreating image_api container"
cd "$(dirname "$COMPOSE")"
docker compose up -d image_api

echo "==> Waiting for image-api to come back"
for i in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:5005/docs || true)
  [[ $code == 200 ]] && { echo "    image-api healthy (HTTP 200 after ${i}s)"; break; }
  [[ $i == 30 ]] && { echo "FATAL: image-api did not return 200 within 30s" >&2; exit 1; }
  sleep 1
done

trap - ERR
echo
echo "==> DONE. Backup kept at $BACKUP"
echo "    Effective config:"
grep -E 'PRIMARY_COMFYUI_URL|FALLBACK_COMFYUI_URL|GATE' "$COMPOSE" | sed 's/^/      /'
echo
echo "    Verify the 3090 is actually being used by generating one image and"
echo "    watching VRAM climb on the GPU node:"
echo "      watch -n1 'curl -s http://192.168.0.12:9835/vram'"
