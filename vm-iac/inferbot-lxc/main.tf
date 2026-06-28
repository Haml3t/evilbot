terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.73"
    }
  }
}

provider "proxmox" {
  endpoint  = "https://192.168.0.145:8006/"
  api_token = var.proxmox_api_token
  insecure  = true
}

resource "proxmox_virtual_environment_container" "inferbot" {
  node_name   = "evilbot"
  vm_id       = var.vm_id
  description = "Inference orchestrator — Nomad server + routing proxy for GPU inference cluster"
  tags        = ["inference", "nomad", "proxy"]

  unprivileged  = true
  start_on_boot = true

  cpu {
    cores = var.cpu_cores
  }

  memory {
    dedicated = var.memory_mb
    swap      = 512
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
        address = var.ip_address == "dhcp" ? "dhcp" : var.ip_address
        gateway = var.ip_address == "dhcp" ? null : "192.168.0.1"
      }
    }

    user_account {
      keys = [var.ssh_public_key]
    }
  }
}
