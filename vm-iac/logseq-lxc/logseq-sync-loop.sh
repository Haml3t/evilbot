#!/bin/bash
# logseq-sync-loop — keep db-sync running for one graph (run by logseq-sync.service as hermes).
#
# `logseq sync start` returns once the websocket is open; the sync client lives in
# the db-worker-node daemon the CLI spawns. That daemon is a child of this loop, so it
# stays inside the service cgroup: stopping the service stops sync cleanly.
# Every 60s: if ws-state is not "open", (re)start sync. The E2EE password is NOT
# passed here — it is persisted once by the operator's first `sync download`/`sync start`
# (stored in ~/logseq/kv-store.json, mode 600, since there is no keychain daemon).
# Self-heal: after MAX_FAILS consecutive failed starts, exit 1 so systemd
# (Restart=always) restarts the whole unit, killing the stuck db-worker daemon.
# Seen 2026-11-19: after a power-loss reboot, `sync start` timed out every
# minute for 4 h; only a service restart reopened the websocket.
set -u
ENV=/home/hermes/.config/logseq-sync.env
MAX_FAILS=${MAX_FAILS:-5}
fails=0
while true; do
  GRAPH=""; [ -r "$ENV" ] && . "$ENV"
  if [ -n "$GRAPH" ]; then
    state=$(logseq sync status --graph "$GRAPH" -o json 2>/dev/null \
      | python3 -c 'import json,sys;print(json.load(sys.stdin)["data"].get("ws-state"))' 2>/dev/null)
    if [ "$state" = "open" ]; then
      fails=0
    else
      echo "ws-state=${state:-unknown}; starting sync for $GRAPH (fail $fails/$MAX_FAILS)"
      out=$(logseq sync start --graph "$GRAPH" -o json 2>&1)
      echo "${out:0:500}"
      if printf '%s' "$out" | grep -q '"ws-state":"open"'; then
        fails=0
      else
        fails=$((fails+1))
        if [ "$fails" -ge "$MAX_FAILS" ]; then
          echo "sync failed $fails times in a row; exiting so systemd restarts the unit"
          exit 1
        fi
      fi
    fi
  fi
  sleep 60
done
