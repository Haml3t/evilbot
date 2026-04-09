terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.73"
    }
  }
}

provider "proxmox" {
  endpoint  = "https://192.168.1.145:8006/"
  api_token = var.proxmox_api_token
  insecure  = true  # self-signed cert on evilbot
}

resource "proxmox_virtual_environment_container" "claudebot" {
  node_name   = "evilbot"
  vm_id       = var.vm_id
  description = "Claude Code sandbox container"
  pool_id     = "claudebots"
  tags        = ["claude", "sandbox"]

  unprivileged = true
  start_on_boot = true

  features {
    nesting = true  # required for Docker-in-container if needed
  }

  cpu {
    cores = var.cpu_cores
  }

  memory {
    dedicated = var.memory_mb
    swap      = 1024
  }

  disk {
    datastore_id = var.disk_storage
    size         = var.disk_size_gb
  }

  network_interface {
    name   = "eth0"
    bridge = "vmbr0"
  }

  operating_system {
    template_file_id = var.template_file_id
    type             = "debian"
  }

  initialization {
    hostname = var.hostname

    ip_config {
      ipv4 {
        address = var.ip_address  # e.g. "dhcp" or "192.168.1.X/24"
        gateway = var.ip_address == "dhcp" ? null : "192.168.1.1"
      }
    }

    user_account {
      keys = [var.ssh_public_key]
    }
  }
}
