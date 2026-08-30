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
  endpoint  = "https://192.168.0.145:8006/"
  api_token = var.proxmox_api_token
  insecure  = true
}

resource "proxmox_virtual_environment_vm" "evilbot_nas" {
  node_name   = "evilbot"
  vm_id       = 100
  name        = "evilbot-nas"
  description = "NAS — Transmission + Samba; /tank shared via virtiofs"
  tags        = ["nas", "media"]

  # ⚠️ pool_id is deliberately NOT set here. Read before adding it.
  #
  # pool_id is ForceNew in bpg/proxmox: declaring it on this already-existing VM
  # plans a DESTROY + recreate. This VM holds the /tank virtiofs mount and is the
  # least rebuildable guest in the fleet — a destroy here is not a rebuild, it is
  # an outage plus manual virtiofs reattachment. Same trap as inferbot-lxc (500)
  # and opsbot-lxc (600); see the comment in vm-iac/inferbot-lxc/main.tf.
  #
  # Correct sequence, if pool membership is ever actually wanted:
  #   1. add VM 100 to the pool out-of-band:  pvesh set /pools/<pool> -vms 100
  #   2. THEN add `pool_id = var.pool_id` here
  #   3. re-plan and confirm "No changes" BEFORE any apply
  # Step 1 first, always.

  on_boot = true
  started = true

  # Startup order: boot early, allow 30s for services to come up
  startup {
    order    = 2
    up_delay = 30
  }

  cpu {
    cores = var.vm_cores
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = var.vm_memory
  }

  scsi_hardware = "virtio-scsi-pci"

  # Verified against live VM 100 on 2026-08-30 via the read-only Proxmox API:
  #   scsi0  tank-vmdata:vm-100-disk-0,discard=on,size=64G,ssd=1
  # discard + ssd must be declared or a recreate silently drops them: discard=on
  # is what lets ZFS reclaim freed blocks from the 64G zvol, and losing it makes
  # the volume grow monotonically toward full on a pool that is already carrying
  # a corrupted-object warning.
  disk {
    datastore_id = var.vm_storage
    size         = 64
    interface    = "scsi0"
    file_format  = "raw"
    discard      = "on"
    ssd          = true
  }

  # `enabled` is deprecated in bpg/proxmox — an empty drive is now expressed as
  # file_id = "none" (matches the live VM's `ide2 none,media=cdrom`).
  cdrom {
    file_id = "none"
  }

  # ostype=l26 on the live VM. Not cosmetic — it drives the QEMU machine/driver
  # defaults Proxmox picks for a Linux guest.
  operating_system {
    type = "l26"
  }

  network_device {
    bridge = var.vm_bridge
    model  = "virtio"

    # Pinned to the live VM's MAC (verified 2026-08-30). This VM is DHCP with no
    # guest agent, and fleet/inventory.yaml records it at 192.168.0.67. If a
    # recreate generates a fresh MAC, the DHCP lease changes, the documented IP
    # becomes wrong, and every host that reaches the NAS by IP breaks until the
    # lease is chased down by hand. Keep this pinned.
    mac_address = var.vm_mac_address
  }

  # virtiofs share — exposes /tank from the host into the VM as "tankshare"
  # NOTE: virtiofs is configured in the Proxmox host config, not via Terraform API.
  # After apply, verify with: ssh root@192.168.0.145 "qm config 100 | grep virtiofs"
  # If missing: ssh root@192.168.0.145 "qm set 100 --virtiofs0 dirid=tankshare,cache=auto"

  agent {
    enabled = false # no QEMU guest agent installed
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
