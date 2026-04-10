#!/usr/bin/env bash
# Provision evilbot-nas after terraform apply (or fresh Ubuntu install).
# Usage: ./provision.sh <vm-ip>
# Secrets: /etc/transmission-remote.env must be created manually after provisioning.
set -euo pipefail

VM_IP="${1:?Usage: $0 <vm-ip>}"
JUMP="root@192.168.1.145"
SCRIPT_DIR="$(dirname "$0")"

echo "==> Provisioning evilbot-nas at $VM_IP"

# Copy config files to VM
scp -J "$JUMP" \
  "$SCRIPT_DIR/ansible/roles/backup/templates/users.yml.j2" \
  "david@$VM_IP:/tmp/" 2>/dev/null || true

ssh -o StrictHostKeyChecking=accept-new -J "$JUMP" "david@$VM_IP" bash << 'ENDSSH'
set -euo pipefail

echo "--- System update ---"
sudo apt-get update -q && sudo apt-get upgrade -y -q

echo "--- Groups ---"
sudo groupadd -f mediagroup
sudo groupadd -f mediaadmingroup
sudo groupadd -f iangroup

echo "--- Users ---"
for u in mediaadmin mediauser ian; do
  sudo useradd -M -s /bin/false -G mediagroup "$u" 2>/dev/null || echo "$u exists"
done
sudo usermod -aG mediaadmingroup mediaadmin 2>/dev/null || true
sudo usermod -aG iangroup ian 2>/dev/null || true

echo "--- /tank mount point ---"
sudo mkdir -p /tank

echo "--- Transmission ---"
sudo apt-get install -y transmission-daemon inotify-tools
sudo systemctl stop transmission-daemon

# Create transmission-remote env file (secrets — fill in real values)
if [[ ! -f /etc/transmission-remote.env ]]; then
  sudo tee /etc/transmission-remote.env > /dev/null << 'ENV'
RPC_HOST=127.0.0.1
RPC_PORT=9091
RPC_USER=evilbot
RPC_PASS=CHANGEME
ENV
  sudo chmod 640 /etc/transmission-remote.env
  sudo chown root:debian-transmission /etc/transmission-remote.env
  echo "IMPORTANT: Update RPC_PASS in /etc/transmission-remote.env"
fi

# transmission-watch script
sudo tee /usr/local/bin/transmission-watch.sh > /dev/null << 'WATCHSCRIPT'
#!/usr/bin/env bash
set -euo pipefail
source /etc/transmission-remote.env

WATCH_ROOT="/tank/watch"
PROCESSED_ROOT="$WATCH_ROOT/Processed"

add_torrent() {
  local f="$1" dest="$2"
  /usr/bin/transmission-remote "${RPC_HOST}:${RPC_PORT}" \
    --auth "${RPC_USER}:${RPC_PASS}" \
    --add "$f" \
    --download-dir "$dest"
}

map_dest() {
  local dirpath="$1" rel dest subrel
  rel="${dirpath#${WATCH_ROOT}/}"
  case "$rel" in
    media/Movies* ) subrel="${rel#media/Movies}"; dest="/tank/media/Movies${subrel}" ;;
    media/TV*     ) subrel="${rel#media/TV}";     dest="/tank/media/TV${subrel}" ;;
    media/Books*  ) subrel="${rel#media/Books}";  dest="/tank/media/Books${subrel}" ;;
    media/Games*  ) subrel="${rel#media/Games}";  dest="/tank/media/Games${subrel}" ;;
    private*      ) subrel="${rel#private}";      dest="/tank/private${subrel}" ;;
    *             ) dest="/tank/media/Upload" ;;
  esac
  echo "$dest"
}

ensure_dir() {
  local d="$1"
  if [[ ! -d "$d" ]]; then
    mkdir -p "$d"
    chown debian-transmission:mediagroup "$d"
    chmod 2775 "$d"
  fi
}

exec /usr/bin/inotifywait -m -r \
  -e close_write -e create -e moved_to \
  --format '%w %f' \
  "$WATCH_ROOT/media/Movies" "$WATCH_ROOT/media/TV" \
  "$WATCH_ROOT/media/Books"  "$WATCH_ROOT/media/Games" \
  "$WATCH_ROOT/private" \
| while read -r dir file; do
    [[ "$file" =~ \.torrent$ ]] || continue
    src="${dir%/}/$file"
    dest_dir="$(map_dest "$dir")"
    ensure_dir "$dest_dir"
    if add_torrent "$src" "$dest_dir"; then
      relpath="${src#${WATCH_ROOT}/}"
      processed_path="${PROCESSED_ROOT}/${relpath}"
      ensure_dir "$(dirname "$processed_path")"
      mv -f -- "$src" "$processed_path"
      echo "Added and archived: $src -> $dest_dir" >&2
    else
      echo "ERROR adding $src -> $dest_dir" >&2
    fi
  done
WATCHSCRIPT
sudo chmod +x /usr/local/bin/transmission-watch.sh

# transmission-watch systemd service
sudo tee /etc/systemd/system/transmission-watch.service > /dev/null << 'SVC'
[Unit]
Description=Watch /tank/watch subdirs and add torrents to Transmission with mapped download dirs
After=network-online.target transmission-daemon.service
Wants=network-online.target
Requires=transmission-daemon.service

[Service]
Type=simple
User=debian-transmission
Group=mediagroup
EnvironmentFile=/etc/transmission-remote.env
ExecStart=/usr/local/bin/transmission-watch.sh
Restart=on-failure
RestartSec=2s

[Install]
WantedBy=multi-user.target
SVC

echo "--- Samba ---"
sudo apt-get install -y samba

sudo tee /etc/samba/smb.conf > /dev/null << 'SAMBA'
[global]
   workgroup = WORKGROUP
   server string = NAS
   map to guest = Bad User
   access based share enum = yes
   log file = /var/log/samba/log.%m
   max log size = 1000
   logging = file

[media]
   path = /tank/media
   browseable = yes
   read only = yes
   valid users = @mediagroup
   write list = mediaadmin david
   force group = mediagroup
   create mask = 0664
   directory mask = 2775
   inherit permissions = yes

[media_upload]
   path = /tank/media/Upload
   browseable = no
   read only = no
   valid users = mediauser mediaadmin david
   force group = mediagroup
   create mask = 0664
   directory mask = 2775
   inherit permissions = yes

[martial_arts_ian]
   path = /tank/media/martial_arts/training_media/ian
   browseable = yes
   read only = no
   valid users = ian mediaadmin david
   force group = iangroup
   create mask = 0664
   directory mask = 2770
   inherit permissions = yes

[private]
   path = /tank/private
   browseable = yes
   read only = no
   valid users = mediaadmin david
   guest ok = no
   force group = mediaadmingroup
   create mask = 0660
   directory mask = 2770
   inherit permissions = yes

[tank_all]
   path = /tank
   browseable = no
   read only = no
   valid users = david
   force group = mediagroup
   create mask = 0664
   directory mask = 2775
   inherit permissions = yes
SAMBA

echo "--- Enable services ---"
sudo systemctl daemon-reload
sudo systemctl enable transmission-daemon transmission-watch smbd nmbd

echo ""
echo "Provisioning complete. Remaining manual steps:"
echo "  1. Mount /tank (virtiofs configured via Proxmox host: qm set 100 --virtiofs0 dirid=tankshare,cache=auto)"
echo "     Add to /etc/fstab: tankshare /tank virtiofs defaults 0 0"
echo "  2. Update RPC_PASS in /etc/transmission-remote.env"
echo "  3. Set Samba passwords: sudo smbpasswd -a <username>"
echo "  4. Start services: sudo systemctl start transmission-daemon transmission-watch smbd nmbd"
ENDSSH

echo "==> Done."
