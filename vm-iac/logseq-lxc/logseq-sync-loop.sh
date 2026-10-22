#!/bin/bash
# logseq-sync-loop — keep db-sync running for one graph (run by logseq-sync.service as hermes).
#
# `logseq sync start` returns once the websocket is open; the sync client lives in
# the db-worker-node daemon the CLI spawns. That daemon is a child of this loop, so it
# stays inside the service cgroup: stopping the service stops sync cleanly.
# Every 60s: if ws-state is not "open", (re)start sync. The E2EE password is NOT
# passed here — it is persisted once by the operator's first `sync download`/`sync start`
# (stored in ~/logseq/kv-store.json, mode 600, since there is no keychain daemon).
set -u
ENV=/home/hermes/.config/logseq-sync.env
while true; do
  GRAPH=""; [ -r "$ENV" ] && . "$ENV"
  if [ -n "$GRAPH" ]; then
    state=$(logseq sync status --graph "$GRAPH" -o json 2>/dev/null \
      | python3 -c 'import json,sys;print(json.load(sys.stdin)["data"].get("ws-state"))' 2>/dev/null)
    if [ "$state" != "open" ]; then
      echo "ws-state=${state:-unknown}; starting sync for $GRAPH"
      logseq sync start --graph "$GRAPH" -o json 2>&1 | head -c 500; echo
    fi
  fi
  sleep 60
done
