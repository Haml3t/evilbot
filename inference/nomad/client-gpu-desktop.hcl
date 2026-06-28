# Nomad client config — runs on gpu-desktop (192.168.0.12)
# Deploy to: /etc/nomad.d/client.hcl on gpu-desktop
# Start with: systemctl enable --now nomad
#
# Prerequisites on gpu-desktop:
#   - Docker installed (already done)
#   - NVIDIA Container Toolkit installed (install if missing — see below)
#   - nomad-device-nvidia plugin binary in /opt/nomad/plugins/
#     Download from: https://releases.hashicorp.com/nomad-device-nvidia/
#
# NVIDIA Container Toolkit install (if missing):
#   curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
#   curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
#     sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
#     tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
#   apt-get update && apt-get install -y nvidia-container-toolkit
#   nvidia-ctk runtime configure --runtime=docker && systemctl restart docker

data_dir  = "/opt/nomad/data"
log_level = "INFO"

# Replace INFERBOT_IP with the actual IP of the inferbot LXC.
client {
  enabled = true
  servers = ["INFERBOT_IP:4647"]
}

datacenter = "gpu-desktop"

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
