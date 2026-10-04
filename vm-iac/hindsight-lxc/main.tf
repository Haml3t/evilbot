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
  insecure  = true # self-signed cert on evilbot
}

resource "proxmox_virtual_environment_container" "hindsight" {
  node_name   = "evilbot"
  vm_id       = var.vm_id
  description = "Hindsight long-term memory server for the Hermes agent — API :8888, dashboard :9999"
  pool_id     = "hermesbots" # set at creation ONLY — pool_id is ForceNew in bpg/proxmox;
                              # adding it to an existing module later plans a destroy.
  # No `tags`: at create time PVE checks tag perms on /vms/<vmid> with pool=undef
  # (GuestHelpers::assert_tag_permissions), which a pool-scoped token cannot pass.

  unprivileged  = true
  start_on_boot = true

  features {
    nesting = true # required to run Docker inside an unprivileged LXC
    # No keyctl: any feature flag other than nesting is root@pam-only
    # (LXC::check_ct_modify_config_perm). If Docker needs it, root runs
    # `pct set 800 --features nesting=1,keyctl=1` in a hermes-grant window.
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
        address = "dhcp"
      }
    }

    user_account {
      keys = [var.ssh_public_key]
    }
  }
}
