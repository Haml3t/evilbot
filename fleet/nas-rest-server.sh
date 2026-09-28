#!/bin/bash
# nas-rest-server.sh — restic REST server on evilbot-nas for personal-machine backups.
#
# Append-only + private repos: each client authenticates as its own htpasswd user,
# can only reach /<user>/, and can ADD snapshots but never delete or rewrite them.
# So root on a backed-up laptop (or an agent holding a time-boxed sudo grant there)
# cannot destroy that laptop's backups. Pruning is done server-side, by root on the
# NAS, with direct filesystem access to the repo.
#
# Data:     /tank/backups/restic/<client>/    (restic-encrypted; the server never sees keys)
# Auth:     /etc/rest-server/htpasswd         (bcrypt; managed out of band, reloaded every 30s)
# Listen:   :8000, plain HTTP on LAN + tailnet (payload is already restic-encrypted;
#           basic-auth creds are append-only-scoped). Restrict with the tailnet ACL.
#
# Idempotent. Run as root on evilbot-nas:   bash nas-rest-server.sh
set -euo pipefail
VER=0.14.0
SHA=4c9c95bc079a0334e81fad379b19dc5c3353c71c2c88d652cafce2081c2b1c66
DATA=/tank/backups/restic

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
[ "$(hostname)" = evilbot-nas ] || { echo "expected evilbot-nas, got $(hostname)" >&2; exit 1; }
mountpoint -q /tank/backups || { echo "/tank/backups not mounted" >&2; exit 1; }

if ! /usr/local/bin/rest-server --version 2>/dev/null | grep -q "$VER"; then
  t=$(mktemp -d)
  curl -fsSL -o "$t/rs.tgz" "https://github.com/restic/rest-server/releases/download/v$VER/rest-server_${VER}_linux_amd64.tar.gz"
  echo "$SHA  $t/rs.tgz" | sha256sum -c --quiet
  tar -xzf "$t/rs.tgz" -C "$t"
  install -m 755 -o root -g root "$t"/rest-server_${VER}_linux_amd64/rest-server /usr/local/bin/rest-server
  rm -rf "$t"
fi

id restic >/dev/null 2>&1 || useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin restic
install -d -m 700 -o restic -g restic "$DATA"
install -d -m 750 -o root -g restic /etc/rest-server
[ -f /etc/rest-server/htpasswd ] || install -m 640 -o root -g restic /dev/null /etc/rest-server/htpasswd

# Client credentials are generated on hermesbot (plaintext stays there) and only the
# bcrypt lines are staged in the hermes user's home. Merge them in, replacing any
# existing line for the same user, then remove the staging file.
STAGE=/home/hermes/rest-htpasswd
if [ -s "$STAGE" ]; then
  grep -qvE '^[a-z0-9-]+:\$2[aby]\$[0-9]{2}\$.{53}$' "$STAGE" && { echo "malformed $STAGE" >&2; exit 1; }
  t=$(mktemp)
  cut -d: -f1 "$STAGE" | sed 's/^/^/;s/$/:/' > "$t.users"
  { grep -vf "$t.users" /etc/rest-server/htpasswd || true; cat "$STAGE"; } > "$t"
  install -m 640 -o root -g restic "$t" /etc/rest-server/htpasswd
  rm -f "$t" "$t.users" "$STAGE"
  echo "htpasswd users: $(cut -d: -f1 /etc/rest-server/htpasswd | tr '\n' ' ')"
fi

cat > /etc/systemd/system/rest-server.service <<EOF
[Unit]
Description=restic REST server (append-only, private repos)
After=network-online.target tank-backups.mount
Wants=network-online.target
RequiresMountsFor=$DATA

[Service]
User=restic
Group=restic
ExecStart=/usr/local/bin/rest-server --path $DATA --listen :8000 --append-only --private-repos --htpasswd-file /etc/rest-server/htpasswd
Restart=on-failure
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=$DATA

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now rest-server
systemctl restart rest-server
for i in $(seq 1 15); do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8000/ || true)
  [ "$code" = 401 ] && { echo "rest-server $VER up on :8000 (unauthenticated -> 401, as expected)"; exit 0; }
  sleep 1
done
echo "rest-server did not answer 401 on :8000" >&2; journalctl -u rest-server -n 20 --no-pager >&2; exit 1
