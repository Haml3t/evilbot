#!/bin/bash
# logseq-backup — hourly SQLite snapshot of the synced graph, then prune:
#   auto snapshots:   every one from the last 24h; then one per 8h UTC slot (00/08/16) up to
#                     7 days old; nothing older.
#   manual snapshots (any name without "-auto-", e.g. pre-write backups from Hermes tasks):
#                     deleted after 48h.
# Steady state ~42 auto + ~2 days of manual (~100 MB each), well inside the 12G disk.
# Snapshots land in ~/logseq/graphs/<graph>/backup/ and are covered by the nightly
# vzdump of CT 810 (nightly-guests job) for anything older.
# Restore: logseq graph backup restore --graph <graph> --src <name>  (stop sync first).
# DRY_RUN=1 skips the new snapshot and only prints what would be pruned.
set -euo pipefail
. /home/hermes/.config/logseq-sync.env
[ -n "${GRAPH:-}" ] || { echo "GRAPH unset; nothing to back up"; exit 0; }
[ -n "${DRY_RUN:-}" ] || logseq graph backup create --graph "$GRAPH" --name auto | tail -1

victims=$(logseq graph backup list --graph "$GRAPH" -o json | python3 -c '
import json, sys, time
HOUR = 3600
now = time.time()
kept_slots = set()
out = []
backups = sorted(json.load(sys.stdin)["data"]["backups"], key=lambda x: x["created-at"], reverse=True)
for b in backups:  # newest first, so each 8h slot keeps its newest snapshot
    age = now - b["created-at"]
    if "-auto-" not in b["name"]:
        if age > 48 * HOUR:
            out.append(b["name"])
        continue
    if age <= 24 * HOUR:
        continue
    if age > 7 * 24 * HOUR:
        out.append(b["name"])
        continue
    slot = int(b["created-at"] // (8 * HOUR))
    if slot in kept_slots:
        out.append(b["name"])
    else:
        kept_slots.add(slot)
print("\n".join(out))
')

for n in $victims; do
  if [ -n "${DRY_RUN:-}" ]; then
    echo "would prune $n"
  else
    logseq graph backup remove --graph "$GRAPH" --src "$n" >/dev/null
    echo "pruned $n"
  fi
done
exit 0
