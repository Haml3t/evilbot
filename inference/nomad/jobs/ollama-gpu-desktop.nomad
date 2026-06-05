# Ollama LLM service on gpu-desktop (RTX 3090, 24GB VRAM)
# Serves larger quantized models: Mistral 34B Q4, Mixtral 8x7B Q4
#
# After deploying, pull models:
#   curl -X POST http://192.168.1.12:11434/api/pull -d '{"name": "mistral:34b-instruct-q4_0"}'
#
# Note: Llama 3 70B Q4 (~40GB) exceeds the RTX 3090's 24GB — not supported.
# Largest practical model: Mistral 34B Q4 (~18-20GB), Mixtral 8x7B Q4 (~26GB, marginal).
#
# Deploy: nomad job run ollama-gpu-desktop.nomad

job "ollama-gpu-desktop" {
  datacenters = ["gpu-desktop"]
  type        = "service"

  group "ollama" {
    count = 1

    network {
      port "api" {
        static = 11434
      }
    }

    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "delay"
    }

    volume "ollama-data" {
      type      = "host"
      read_only = false
      source    = "ollama-gpu-desktop"
    }

    task "server" {
      driver = "docker"

      config {
        image = "ollama/ollama:latest"
        ports = ["api"]

        security_opt = ["no-new-privileges"]
        cap_drop     = ["ALL"]
        cap_add      = ["NET_BIND_SERVICE", "SYS_RESOURCE"]
      }

      env {
        OLLAMA_HOST    = "0.0.0.0"
        OLLAMA_ORIGINS = "*"
      }

      volume_mount {
        volume      = "ollama-data"
        destination = "/root/.ollama"
        read_only   = false
      }

      resources {
        cpu    = 4000  # gpu-desktop has more cores
        memory = 16384 # MB — large models need more system RAM for context

        device "nvidia/gpu" {
          count = 1
          constraint {
            attribute = "${device.attr.memory}"
            operator  = ">="
            value     = "16384"  # 16 GB — only gpu-desktop's RTX 3090 (24GB) qualifies
          }
        }
      }

      service {
        name     = "ollama-gpu-desktop"
        port     = "api"
        provider = "nomad"

        check {
          type     = "http"
          path     = "/api/tags"
          interval = "30s"
          timeout  = "10s"
        }
      }
    }
  }
}
