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
  insecure  = true
}

resource "proxmox_virtual_environment_vm" "evilbot_telegram" {
  node_name   = "evilbot"
  vm_id       = 200
  name        = "evilbot-telegram"
  description = "Telegram bot + image generation frontend"
  tags        = ["telegram", "bot"]

  on_boot  = true
  started  = true

  cpu {
    cores = 2
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = 4096
  }

  # Boot disk — restored from backup or provisioned from Ubuntu cloud image
  disk {
    datastore_id = "local-lvm"
    size         = 32
    interface    = "scsi0"
    file_format  = "raw"
  }

  network_device {
    bridge = "vmbr0"
  }

  # No guest agent installed — management via SSH only
  agent {
    enabled = false
  }

  initialization {
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    user_account {
      username = "ubuntu"
      keys     = [var.ssh_public_key]
    }
  }
}
