#!/bin/bash
# satellite-gate.sh <host> — run on hermesbot as `hermes`. Decides whether a personal
# machine meets the baseline required before Hermes' key stays "always accepted"
# and before any broad sudo window is used there. Every line is PASS or FAIL;
# exit status is the number of FAILs (0 = gate passed).
#
# Uses ~/.hermes/fleet/inventory.ini for connection details.
set -uo pipefail
H="${1:?usage: satellite-gate.sh <host>}"
INV="${INV:-$HOME/.hermes/fleet/inventory.ini}"
PB="$(cd "$(dirname "$0")" && pwd)/ansible/satellite.yml"
fails=0
ok()  { echo "PASS $*"; }
bad() { echo "FAIL $*"; fails=$((fails+1)); }
r()   { ssh -o BatchMode=yes -o ConnectTimeout=10 "${SSHOPT[@]}" "hermes@$ADDR" "$1" 2>&1; }

# connection details from the (private) inventory line for $H
line=$(grep -E "^$H[[:space:]]" "$INV") || { echo "no '$H' in $INV" >&2; exit 99; }
ADDR=$(sed -nE 's/.*ansible_host=([^ ]+).*/\1/p' <<<"$line")
SSHOPT=(); grep -q 'tailscale nc' <<<"$line" && SSHOPT=(-o "ProxyCommand=tailscale nc %h %p")
r 'true' >/dev/null && ok "reachable as hermes ($ADDR)" || { bad "unreachable as hermes ($ADDR)"; exit $fails; }

# 1. no ambient root: sudo only for the allowlist, no open grant window
out=$(r 'sudo -n /usr/bin/true 2>&1; echo rc=$?')
echo "$out" | grep -q 'rc=0' && bad "hermes has unrestricted sudo right now (grant open?)" || ok "no unrestricted sudo"
out=$(r 'id -Gn')
[ "$(echo "$out" | tr -d ' \n')" = hermes ] && ok "hermes in no extra groups" || bad "hermes groups: $out"
out=$(r 'test -e /etc/sudoers.d/hermes-temp && echo OPEN || echo closed')
echo "$out" | grep -q closed && ok "no grant window open" || bad "grant window open"

# 2. isolation: other homes unreadable
out=$(r 'for d in /home/*; do [ "$d" = /home/hermes ] && continue; ls "$d" >/dev/null 2>&1 && echo "READABLE $d"; done; echo done')
echo "$out" | grep -q READABLE && bad "hermes can read: $(echo "$out" | grep READABLE | tr '\n' ' ')" || ok "other users' homes unreadable"

# 3. backups: recent snapshot + restore test + append-only proof
out=$(r 'sudo -n /usr/local/sbin/hermes-backup-status')
age=$(echo "$out" | sed -nE 's/.*age_h=([0-9]+).*/\1/p')
[ -n "$age" ] && [ "$age" -lt 26 ] && ok "latest snapshot ${age}h old" || bad "backup status: $out"
out=$(r 'sudo -n /usr/local/sbin/hermes-backup-verify')
echo "$out" | grep -E '^(PASS|FAIL)' | sed 's/^/  /'
echo "$out" | grep -q '^FAIL' && bad "backup verify" || { echo "$out" | grep -q 'PASS append-only' && ok "restore test + append-only" || bad "backup verify produced no result"; }
out=$(r 'systemctl is-enabled hermes-backup.timer')
echo "$out" | grep -q enabled && ok "backup timer enabled" || bad "backup timer: $out"

# 4. config matches the playbook (check mode needs root, so this reads the stamp)
out=$(r 'cat /etc/hermes-satellite.version 2>/dev/null || echo none')
rev=$(git -C "$(dirname "$PB")" log -1 --format=%h -- .)
echo "$out" | grep -q "^$rev " && ok "playbook rev $rev applied" || bad "applied rev '$out' != repo $rev (re-run playbook)"

echo "--- $H: $fails failure(s)"
exit $fails
