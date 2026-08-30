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

resource "proxmox_virtual_environment_container" "opsbot" {
  node_name   = "evilbot"
  vm_id       = var.vm_id
  description = "Ops/deploy LXC — GitHub Actions self-hosted runner, deploy automation, health monitoring"
  tags        = ["ops", "ci", "deploy"]

  # ⚠️ pool_id is deliberately NOT set here. Read before adding it.
  #
  # The terraform-lxc@pve!lxc token was re-scoped on 2026-06-07 from PVEAdmin on /
  # to the custom ClaudebotLXC role on /pool/claudebots, and this container (600)
  # is NOT a member of that pool. So a *recreate* through this module would 403.
  #
  # The obvious fix — adding `pool_id = "claudebots"` — is WORSE than the problem:
  # pool_id is ForceNew in bpg/proxmox, so declaring it on this existing container
  # plans a DESTROY + recreate, which would wipe the GitHub Actions runner.
  # Verified against the identical case on inferbot (CT 500) on 2026-08-29.
  #
  # Correct sequence, when someone wants to close this properly:
  #   1. add CT 600 to the pool out-of-band:  pvesh set /pools/claudebots -vms 600
  #   2. THEN add `pool_id = "claudebots"` here
  #   3. re-plan and confirm it reports "No changes" before any apply
  # Step 1 first, always. Never add the attribute to a container already outside the pool.

  unprivileged  = true
  start_on_boot = true

  cpu {
    cores = var.cpu_cores
  }

  memory {
    dedicated = var.memory_mb
    swap      = 256
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
