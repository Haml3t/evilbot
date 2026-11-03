#!/bin/bash
# logseq-backup — hourly SQLite snapshot of the synced graph, keep the newest 72 (3 days).
# Snapshots land in ~/logseq/graphs/<graph>/backup/ and are covered by the nightly
# vzdump of CT 810, giving: hourly x 3 days on-box + vzdump daily/weekly/monthly off-box.
# Restore: logseq graph backup restore --graph <graph> --src <name>  (stop sync first).
set -euo pipefail
. /home/hermes/.config/logseq-sync.env
[ -n "${GRAPH:-}" ] || { echo "GRAPH unset; nothing to back up"; exit 0; }
logseq graph backup create --graph "$GRAPH" --name auto | tail -1
logseq graph backup list --graph "$GRAPH" -o json | python3 -c '
import json,sys
b=[x for x in json.load(sys.stdin)["data"]["backups"] if "-auto-" in x["name"]]
b.sort(key=lambda x:x["created-at"])
print("\n".join(x["name"] for x in b[:-72]))' | while read -r n; do
  [ -n "$n" ] && logseq graph backup remove --graph "$GRAPH" --src "$n" >/dev/null && echo "pruned $n"
done
