# ComfyUI service on evilbot (RTX 3070, 8GB VRAM)
# Handles small/medium image gen models: SD 1.5, SDXL base
#
# Before deploying, pin the image digest from evilbot:
#   docker image inspect yanwk/comfyui-boot:cu124-slim --format '{{join .RepoDigests "\n"}}'
# Replace <SHA256_DIGEST> below with the full sha256 hash.
#
# Deploy: nomad job run comfyui-evilbot.nomad

job "comfyui-evilbot" {
  datacenters = ["evilbot"]
  type        = "service"

  group "comfyui" {
    count = 1

    network {
      port "http" {
        static = 8188
      }
    }

    restart {
      attempts = 3
      interval = "5m"
      delay    = "30s"
      mode     = "delay"
    }

    task "server" {
      driver = "docker"

      config {
        image = "yanwk/comfyui-boot@sha256:<SHA256_DIGEST>"
        ports = ["http"]

        volumes = [
          "/data/comfyui-evilbot:/root",
        ]

        # No new privileges, no root escalation
        security_opt = ["no-new-privileges"]
        cap_drop     = ["ALL"]
        cap_add      = ["NET_BIND_SERVICE", "SYS_RESOURCE"]
      }

      env {
        CLI_ARGS = "--disable-cuda-malloc --listen 0.0.0.0"
      }

      resources {
        cpu    = 2000  # MHz
        memory = 4096  # MB system RAM

        device "nvidia/gpu" {
          count = 1
          constraint {
            attribute = "${device.attr.memory}"
            operator  = ">="
            value     = "6144"  # 6 GB — fits RTX 3070 (8GB)
          }
        }
      }

      service {
        name     = "comfyui-evilbot"
        port     = "http"
        provider = "nomad"

        check {
          type     = "http"
          path     = "/system_stats"
          interval = "30s"
          timeout  = "10s"
        }
      }
    }
  }
}
