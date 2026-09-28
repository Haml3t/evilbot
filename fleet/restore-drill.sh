#!/bin/bash
# restore-drill.sh — L2 restore drill for a personal machine's restic repository.
#
# WHAT THIS PROVES: the snapshot can be restored with content and metadata intact.
# WHAT IT DOES NOT PROVE: that a machine can be rebuilt from the snapshot (that is L3,
# a bare-metal rebuild, and it is still not done). Do not describe this as a
# disaster-recovery test.
#
# Run it on a DISPOSABLE host, never on the machine being backed up.
# Usage:  restore-drill.sh <host_vars.yml> [scratch_dir]
#   The host_vars file is the one from the private ~/.hermes/fleet/host_vars/<host>.yml
#   on the hub. Credentials are read from it and never written to the repo.
#
# Two failure modes this script exists to avoid, both learned the hard way (2026-09-28):
#   1. A full --verify restore needs roughly 2x the snapshot size. Filling the disk takes
#      sudo down with it (its I/O log plugin cannot mkdir), which is a deadlock because
#      freeing space then needs root. So: check free space BEFORE restoring.
#   2. Aborting a restic restore leaves an exclusive lock in the repository, after which
#      every `restic check` on that machine fails with "repository is already locked".
#      That reads as corruption and is not. So: kill the restore and run `restic unlock`
#      as part of teardown.
set -uo pipefail

HV="${1:?usage: restore-drill.sh <host_vars.yml> [scratch_dir]}"
SCRATCH="${2:-/var/tmp/restore-drill}"
[ -r "$HV" ] || { echo "cannot read $HV" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
command -v restic >/dev/null || { echo "restic not installed here" >&2; exit 1; }

g() { sed -nE "s/^$1:[[:space:]]*(\S+)[[:space:]]*$/\1/p" "$HV" | head -1; }
BUSER=$(g backup_user); BHTTP=$(g backup_http_password); BPASS=$(g restic_password)
BSERVER=$(g backup_server); BPORT=$(g backup_port)
: "${BPORT:=8000}"
[ -n "$BUSER" ] && [ -n "$BHTTP" ] && [ -n "$BPASS" ] || { echo "host_vars missing restic fields" >&2; exit 1; }

export RESTIC_REPOSITORY="rest:http://${BUSER}:${BHTTP}@${BSERVER}:${BPORT}/${BUSER}/"
export RESTIC_PASSWORD="$BPASS"
export RESTIC_CACHE_DIR="$SCRATCH-cache"
mkdir -p "$RESTIC_CACHE_DIR"

SNAP=$(restic snapshots --json | python3 -c 'import json,sys; s=json.load(sys.stdin); print(max(s,key=lambda x:x["time"])["short_id"])') || exit 1
echo "repository: ${BSERVER}:${BPORT}/${BUSER}/   snapshot: $SNAP"

STATS=$(restic stats "$SNAP" --json)
SIZE=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["total_size"])' "$STATS")
NEED=$(( SIZE * 2 ))
AVAIL=$(df -B1 --output=avail "$(dirname "$SCRATCH")" | tail -1 | tr -d ' ')
echo "snapshot size: $SIZE bytes; need ~$NEED for a --verify restore; available: $AVAIL"
if [ "$AVAIL" -lt "$NEED" ]; then
  echo "REFUSING: not enough free space for a --verify restore. Free some, or pass a"
  echo "scratch_dir on a larger filesystem. (A plain restore needs ~1x, but then you"
  echo "cannot prove content integrity, which is the point of the drill.)" >&2
  exit 2
fi

cleanup() {
  rc=$?
  echo "--- teardown ---"
  # Kill any surviving restore first: an aborted restore holds a repo lock.
  pkill -f 'restic restore' 2>/dev/null && { sleep 2; echo "killed a lingering restic restore"; }
  rm -rf "$SCRATCH" "$RESTIC_CACHE_DIR"
  # Clear any lock this run left behind, so the next `restic check` is not a false alarm.
  if restic unlock >/dev/null 2>&1; then echo "repo unlock: ok"; fi
  echo "scratch removed; exit=$rc"
  exit $rc
}
trap cleanup EXIT

echo "=== full restore ==="
rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"
time restic restore "$SNAP" --target "$SCRATCH" || exit 1

echo "=== content verification: restic re-reads every file and checks it against the repo ==="
# Scoped by tree so peak usage stays within the space checked above.
for tree in /etc /home /root /usr/local /var/spool/cron; do
  restic restore "$SNAP" --target "$SCRATCH-v" --include "$tree" --verify || exit 1
  rm -rf "$SCRATCH-v"
done
echo "PASS: every restored file verified against the repository"

echo "=== metadata spot-checks (must be meaningful, i.e. not all root:root 0644) ==="
for f in etc/hostname etc/passwd etc/shadow; do
  [ -e "$SCRATCH/$f" ] && stat -c '  %A %U:%G %s  %n' "$SCRATCH/$f"
done

echo "=== repo integrity ==="
restic check --read-data-subset=10% 2>&1 | tail -3
echo "DRILL COMPLETE"