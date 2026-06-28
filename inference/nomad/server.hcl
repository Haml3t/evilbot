# Nomad server config — runs on inferbot LXC
# Deploy to: /etc/nomad.d/server.hcl on inferbot
# Start with: systemctl enable --now nomad

data_dir  = "/opt/nomad/data"
log_level = "INFO"

# Bind to all interfaces; advertise inferbot's LAN IP so agents can reach it.
# Replace INFERBOT_IP with the actual IP assigned to inferbot (e.g. 192.168.0.223).
bind_addr = "0.0.0.0"

advertise {
  http = "INFERBOT_IP:4646"
  rpc  = "INFERBOT_IP:4647"
  serf = "INFERBOT_IP:4648"
}

server {
  enabled          = true
  bootstrap_expect = 1  # single-server cluster
}

ui {
  enabled = true
}
