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

resource "proxmox_virtual_environment_container" "hermesbot" {
  node_name   = "evilbot"
  vm_id       = var.vm_id
  description = "Hermes Agent — always-on homelab ops agent (gateway + cron). Managed by Terraform."
  tags        = ["agent", "hermes", "ops"]

  # REQUIRED: the terraform-lxc@pve!lxc token was re-scoped on 2026-06-07 from
  # PVEAdmin on / to the custom ClaudebotLXC role on /pool/claudebots. A container
  # created outside that pool returns 403. The older *-lxc modules in this repo
  # predate the re-scope and omit this — do not copy that omission.
  pool_id = var.pool_id

  unprivileged  = true
  start_on_boot = true

  cpu {
    cores = var.cpu_cores
  }

  memory {
    dedicated = var.memory_mb
    swap      = var.swap_mb
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
