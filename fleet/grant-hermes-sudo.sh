#!/bin/bash
# Grant the `hermes` service account Tier 1/2 write authority.
#
# RUN AS ROOT ON evilbot.  Idempotent — safe to re-run.
#
#   Tier 1  devbox-301 (301)  dev sandbox, fully reproducible (tf + 4 provision scripts)
#   Tier 2  jellyfin   (400)  service container, tf + provision
#   Tier 2  inferbot   (500)  Nomad server + inference proxy, tf + provision
#   Tier 2  opsbot     (600)  ops container, tf + provision
#
# Authority is granted in proportion to REBUILDABILITY, not to trust. All four of
# these rebuild from vm-iac/, so full root on them is recoverable and is granted in
# full. Deliberately NOT granted here:
#
#   evilbot           hypervisor — no IaC; root implies every guest and 22TB of pool
#   evilbot-nas       no Terraform module at all, and mounts /tank
#   evilbot-telegram  holds TELEGRAM_BOT_TOKEN in /opt/evilbot/.env
#
# Those are Tier 3/4 and get a scoped allowlist, decided separately.
#
# A malformed sudoers file locks EVERYONE out of root, including you. Every file is
# therefore validated with `visudo -c` before installation, and the complete sudoers
# tree is re-validated afterwards with automatic rollback on failure.

set -uo pipefail
TARGETS="301 400 500 600"

cat > /tmp/_sudo.sh <<'INNER'
#!/bin/bash
set -u

# sudo is absent from the minimal Debian LXC template used for 301/500/600.
if ! command -v sudo >/dev/null 2>&1; then
  echo "    installing sudo..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1
  apt-get install -y -qq --no-install-recommends sudo >/dev/null 2>&1 \
    || { echo "    FAILED to install sudo"; exit 1; }
fi

install -d -m 700 /var/log/sudo-io
# Clean up the literal '%{seq}' directory left by the first revision of this script.
rm -rf '/var/log/sudo-io/hermes/%{seq}' 2>/dev/null

# log_input/log_output give full session replay. rsyslog is inactive on most of
# these hosts, so journald plus this I/O log is the entire audit trail — it is the
# difference between "something broke" and "here is the command that broke it".
# These hosts are low-traffic and rebuildable, so the disk cost is worth paying.
cat > /tmp/_hermes_sudoers <<'SUDOERS'
# Hermes agent — Tier 1/2 write authority.
# Managed from fleet/grant-hermes-sudo.sh in the evilbot repo. Do not hand-edit.
Defaults:hermes !requiretty
Defaults:hermes logfile=/var/log/sudo-hermes.log
Defaults:hermes log_input, log_output
# %{seq} must go in iolog_file, NOT iolog_dir — sudo expands %{user} in a dir but
# leaves %{seq} literal there, producing a directory named '%{seq}'.
Defaults:hermes iolog_dir=/var/log/sudo-io/%{user}
Defaults:hermes iolog_file=%{seq}
hermes ALL=(ALL) NOPASSWD: ALL
SUDOERS

if ! visudo -cf /tmp/_hermes_sudoers >/dev/null 2>&1; then
  echo "    REFUSED: fragment failed validation, nothing installed"
  visudo -cf /tmp/_hermes_sudoers
  rm -f /tmp/_hermes_sudoers
  exit 1
fi

install -m 440 -o root -g root /tmp/_hermes_sudoers /etc/sudoers.d/hermes
rm -f /tmp/_hermes_sudoers

# Re-validate the WHOLE tree, not just our fragment, and roll back if it broke.
if ! visudo -c >/dev/null 2>&1; then
  echo "    ROLLBACK: full sudoers tree invalid after install"
  rm -f /etc/sudoers.d/hermes
  exit 1
fi

echo "    $(hostname): sudoers=ok  iolog=/var/log/sudo-io"
INNER
chmod +x /tmp/_sudo.sh

for id in $TARGETS; do
  echo "=== CT $id ==="
  pct status "$id" 2>/dev/null | grep -q running || { echo "    SKIP (not running)"; continue; }
  pct push "$id" /tmp/_sudo.sh /tmp/_sudo.sh --perms 755 >/dev/null 2>&1
  pct exec "$id" -- /tmp/_sudo.sh
  pct exec "$id" -- rm -f /tmp/_sudo.sh
done

rm -f /tmp/_sudo.sh
echo
echo "Done. Verify from hermesbot:"
echo "  su - hermes -c 'ssh devbox sudo -n id'      # expect uid=0(root)"
echo "  su - hermes -c 'ssh nas sudo -n id'         # expect a refusal (Tier 3)"
