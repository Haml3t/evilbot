# ComfyUI service on gpu-desktop (RTX 3090, 24GB VRAM)
# Handles large image gen models: SDXL+refiner, Flux.1
#
# Use the same pinned digest as comfyui-evilbot.nomad.
#
# Deploy: nomad job run comfyui-gpu-desktop.nomad

job "comfyui-gpu-desktop" {
  datacenters = ["gpu-desktop"]
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
          "/data/comfyui-gpu-desktop:/root",
        ]

        security_opt = ["no-new-privileges"]
        cap_drop     = ["ALL"]
        cap_add      = ["NET_BIND_SERVICE", "SYS_RESOURCE"]
      }

      env {
        CLI_ARGS = "--disable-cuda-malloc --listen 0.0.0.0"
      }

      resources {
        cpu    = 4000  # MHz — gpu-desktop has more cores
        memory = 8192  # MB system RAM

        device "nvidia/gpu" {
          count = 1
          constraint {
            attribute = "${device.attr.memory}"
            operator  = ">="
            value     = "20480"  # 20 GB — only gpu-desktop's RTX 3090 (24GB) qualifies
          }
        }
      }

      service {
        name     = "comfyui-gpu-desktop"
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
