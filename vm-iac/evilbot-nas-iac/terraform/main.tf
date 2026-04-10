terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.73"
    }
  }
}

# Migrated from Telmate/proxmox (password auth) to bpg/proxmox (API token auth).
# Token: terraform-lxc@pve!lxc — see /root/.secrets/proxmox-tokens.env on claudebot.
provider "proxmox" {
  endpoint  = "https://192.168.1.145:8006/"
  api_token = var.proxmox_api_token
  insecure  = true
}

resource "proxmox_virtual_environment_vm" "evilbot_nas" {
  node_name   = "evilbot"
  vm_id       = 100
  name        = "evilbot-nas"
  description = "NAS — Transmission + Samba; /tank shared via virtiofs"
  tags        = ["nas", "media"]

  on_boot  = true
  started  = true

  # Startup order: boot early, allow 30s for services to come up
  startup {
    order      = 2
    up_delay   = 30
  }

  cpu {
    cores = var.vm_cores
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = var.vm_memory
  }

  scsi_hardware = "virtio-scsi-pci"

  disk {
    datastore_id = var.vm_storage
    size         = 64
    interface    = "scsi0"
    file_format  = "raw"
  }

  cdrom {
    enabled = false
  }

  network_device {
    bridge  = var.vm_bridge
    model   = "virtio"
  }

  # virtiofs share — exposes /tank from the host into the VM as "tankshare"
  # NOTE: virtiofs is configured in the Proxmox host config, not via Terraform API.
  # After apply, verify with: ssh root@192.168.1.145 "qm config 100 | grep virtiofs"
  # If missing: ssh root@192.168.1.145 "qm set 100 --virtiofs0 dirid=tankshare,cache=auto"

  agent {
    enabled = false  # no QEMU guest agent installed
  }

  initialization {
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    user_account {
      username = var.ci_user
      keys     = [var.ssh_public_key]
    }
  }
}
