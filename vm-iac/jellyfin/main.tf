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

resource "proxmox_virtual_environment_container" "jellyfin" {
  node_name    = "evilbot"
  vm_id        = 400
  description  = "Jellyfin media server"
  pool_id      = "claudebots"
  tags         = ["jellyfin", "media"]

  unprivileged  = true
  start_on_boot = true

  features {
    nesting = true
  }

  cpu {
    cores = 2
  }

  memory {
    dedicated = 4096
    swap      = 1024
  }

  disk {
    datastore_id = "local-lvm"
    size         = 32
  }

  # Read-only bind mount of /tank/media from evilbot host into container
  mount_point {
    path      = "/media"
    volume    = "/tank/media"
    read_only = true
  }

  network_interface {
    name   = "eth0"
    bridge = "vmbr0"
  }

  operating_system {
    template_file_id = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
    type             = "debian"
  }

  initialization {
    hostname = "jellyfin"

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    user_account {
      keys = [var.ssh_public_key]
    }
  }
}
