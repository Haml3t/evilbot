# Ollama LLM service on evilbot (RTX 3070, 8GB VRAM)
# Serves small quantized models: Llama 3 8B Q4, Mistral 7B Q4
#
# After deploying, pull models:
#   docker exec <container> ollama pull llama3:8b-instruct-q4_0
#   docker exec <container> ollama pull mistral:7b-instruct-q4_0
#
# Or use the Ollama API from inferbot:
#   curl -X POST http://192.168.1.145:11434/api/pull -d '{"name": "llama3:8b-instruct-q4_0"}'
#
# Deploy: nomad job run ollama-evilbot.nomad

job "ollama-evilbot" {
  datacenters = ["evilbot"]
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
      source    = "ollama-evilbot"
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
        cpu    = 2000
        memory = 4096

        device "nvidia/gpu" {
          count = 1
          constraint {
            attribute = "${device.attr.memory}"
            operator  = ">="
            value     = "4096"  # 4 GB minimum — small quantized models
          }
        }
      }

      service {
        name     = "ollama-evilbot"
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
