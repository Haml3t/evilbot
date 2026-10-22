#!/bin/bash
# install-logseq-cli.sh <version> — install/upgrade the headless Logseq DB CLI on CT 810.
#
# The sync-capable CLI (login, sync, graph backup) ships ONLY inside the desktop
# release's app.asar. The npm package @logseq/cli is the old pre-sync CLI — do not use it.
#
# Layout (run as root on CT 810):
#   /opt/node                       Node LTS (tarball, sha256-verified)
#   /opt/logseq/<version>/          extracted app.asar + app.asar.unpacked/node_modules
#   /opt/logseq/extra-<version>/    modules the desktop build relies on Electron's
#                                   bundle for; loaded via NODE_PATH, never mixed in
#   /opt/logseq/current -> <version>
#   /usr/local/bin/logseq           wrapper (sets NODE_PATH)
#
# Upgrade policy: match the desktop version the operator runs on their desktop, and only after he
# has upgraded there. Old versions stay on disk; rollback = repoint `current`.
set -euo pipefail
V="${1:?usage: $0 <logseq-version e.g. 2.0.2>}"
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
command -v node >/dev/null || { echo "install Node to /opt/node first (see RUNBOOK)" >&2; exit 1; }

D=/opt/logseq/$V
X=/opt/logseq/extra-$V
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

if [ ! -f "$D/logseq-cli.js" ]; then
  curl -fsSL -o "$TMP/l.zip" "https://github.com/logseq/logseq/releases/download/$V/Logseq-linux-x86_64-$V.zip"
  unzip -q "$TMP/l.zip" -d "$TMP/x"
  rm -rf "$D"
  npx -y @electron/asar extract "$TMP/x/resources/app.asar" "$D"
  cp -a "$TMP/x/resources/app.asar.unpacked/node_modules/." "$D/node_modules/"
  cp -a "$TMP/x/resources/.agents" "$D/.agents"   # bundled logseq-cli SKILL.md (`logseq skill show`)
fi

# Modules required by db-worker-node.js but not shipped in node_modules. Versions
# come from the release's own package.json so they track the upstream pin.
curl -fsSL -o "$TMP/pkg.json" "https://raw.githubusercontent.com/logseq/logseq/$V/package.json"
mapfile -t MISSING < <(cd "$D" && grep -o 'require("[^".][^"]*")' db-worker-node.js logseq-cli.js \
  | sed 's/.*require("\(.*\)")/\1/' | grep -v '^node:' | sort -u | while read -r m; do
      b=$(case $m in @*) echo "$m" | cut -d/ -f1-2;; *) echo "$m" | cut -d/ -f1;; esac)
      node -e "require('module').isBuiltin('$b')||process.exit(1)" && continue
      [ -e "node_modules/$b" ] || echo "$b"; done | sort -u)
SPECS=()
for m in "${MISSING[@]}"; do
  ver=$(python3 -c "import json,sys;d=json.load(open('$TMP/pkg.json'));a={**d.get('devDependencies',{}),**d.get('dependencies',{})};print(a.get('$m',''))")
  SPECS+=("$m${ver:+@$ver}")
done
mkdir -p "$X"
if [ ${#SPECS[@]} -gt 0 ]; then
  echo "installing missing modules: ${SPECS[*]}"
  (cd "$X" && npm install --no-save --no-audit --no-fund --ignore-scripts --prefix "$X" "${SPECS[@]}" >/dev/null)
fi
chown -R hermes:hermes "$D" "$X"

cat > /usr/local/bin/logseq <<'EOF'
#!/bin/sh
V=$(basename "$(readlink -f /opt/logseq/current)")
export NODE_PATH=/opt/logseq/extra-$V/node_modules
exec /opt/node/bin/node /opt/logseq/current/logseq-cli.js "$@"
EOF
chmod 755 /usr/local/bin/logseq
ln -sfn "$D" /opt/logseq/current
echo "logseq CLI -> $(readlink -f /opt/logseq/current)"
