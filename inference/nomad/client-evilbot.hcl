# Nomad client config — runs on the evilbot Proxmox host
# Deploy to: /etc/nomad.d/client.hcl on evilbot (192.168.1.145)
# Start with: systemctl enable --now nomad
#
# Prerequisites on evilbot:
#   - Docker installed (already done)
#   - NVIDIA Container Toolkit installed (already done)
#   - nomad-device-nvidia plugin binary in /opt/nomad/plugins/
#     Download from: https://releases.hashicorp.com/nomad-device-nvidia/

data_dir  = "/opt/nomad/data"
log_level = "INFO"

# Replace INFERBOT_IP with the actual IP of the inferbot LXC.
client {
  enabled = true
  servers = ["INFERBOT_IP:4647"]
}

datacenter = "evilbot"

plugin "docker" {
  config {
    allow_privileged = false
    volumes {
      enabled = true
    }
    gc {
      image       = true
      image_delay = "3m"
      container   = true
    }
  }
}

plugin "nvidia-gpu" {
  config {
    enabled            = true
    fingerprint_period = "1m"
    jobs_enabled       = true
  }
}

plugin_dir = "/opt/nomad/plugins"
