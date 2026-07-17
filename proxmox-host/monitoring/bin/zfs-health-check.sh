#!/usr/bin/env bash
# zfs-health-check.sh — daily safety net on evilbot.
# Catches conditions ZED won't re-fire for: an ALREADY-degraded pool, and early
# SMART wear (pending/reallocated sectors, CRC errors) on drives still reporting PASSED.
# Alerts to Telegram only when something is wrong (no news = healthy).
set -uo pipefail

NOTIFY=/usr/local/bin/notify-telegram.sh
problems=""

# Genuine execution failure (not "problem found") -> non-zero so systemd OnFailure fires.
if ! command -v zpool >/dev/null 2>&1; then
  echo "FATAL: zpool not found" >&2
  exit 2
fi

# --- ZFS pool health ---
if ! zpool status -x 2>/dev/null | grep -q "all pools are healthy"; then
  problems="${problems}ZFS pool NOT healthy:
$(zpool status -x 2>/dev/null)

"
fi

# --- Pool capacity (ZFS degrades/CoW-starves when near-full) ---
cap="$(zpool list -H -o capacity tank 2>/dev/null | tr -d '% ')"
if [ -n "${cap:-}" ]; then
  if [ "$cap" -ge 90 ]; then
    problems="${problems}tank capacity CRITICAL: ${cap}% used (ZFS performance/space at risk).

"
  elif [ "$cap" -ge 80 ]; then
    problems="${problems}tank capacity high: ${cap}% used (plan cleanup/expansion).

"
  fi
fi

# --- SMART: SATA/SAS spinning disks ---
for d in /dev/sd?; do
  [ -e "$d" ] || continue
  health="$(smartctl -H -d sat "$d" 2>/dev/null | grep -iE 'overall-health|SMART Health Status')"
  if ! echo "$health" | grep -qiE 'PASSED|OK'; then
    problems="${problems}SMART health FAILED on ${d}:
${health}

"
  fi
  attrs="$(smartctl -A -d sat "$d" 2>/dev/null)"
  pend="$(echo "$attrs"   | awk '/Current_Pending_Sector/  {print $10+0; exit}')"
  realloc="$(echo "$attrs"| awk '/Reallocated_Sector_Ct/   {print $10+0; exit}')"
  crc="$(echo "$attrs"    | awk '/UDMA_CRC_Error_Count/     {print $10+0; exit}')"
  offu="$(echo "$attrs"   | awk '/Offline_Uncorrectable/    {print $10+0; exit}')"
  warn=""
  [ "${pend:-0}"    -gt 0 ] && warn="${warn} pending=${pend}"
  [ "${realloc:-0}" -gt 0 ] && warn="${warn} reallocated=${realloc}"
  [ "${offu:-0}"    -gt 0 ] && warn="${warn} offline_uncorrectable=${offu}"
  [ "${crc:-0}"     -gt 0 ] && warn="${warn} crc_errors=${crc}"
  if [ -n "$warn" ]; then
    problems="${problems}Early SMART wear on ${d}:${warn}

"
  fi
done

# --- SMART: NVMe ---
for d in /dev/nvme?n?; do
  [ -e "$d" ] || continue
  if ! smartctl -H "$d" 2>/dev/null | grep -qiE 'PASSED|OK'; then
    problems="${problems}NVMe SMART health FAILED on ${d}

"
  fi
done

# Finding problems is a SUCCESSFUL run (we alerted). Exit 0 so systemd OnFailure is
# reserved for genuine "the check couldn't run" failures.
if [ -n "$problems" ]; then
  [ -x "$NOTIFY" ] && "$NOTIFY" "$(printf '🩺 evilbot daily health check found issues:\n\n%s' "$problems")"
fi
exit 0
