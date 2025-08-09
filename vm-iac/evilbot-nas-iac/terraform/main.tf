terraform {
  required_providers {
    proxmox = {
      source  = "Telmate/proxmox"
      version = "2.9.14" # or latest known stable
    }
  }
}

provider "proxmox" {
  pm_api_url = "https://192.168.1.145:8006/api2/json"
  pm_user    = "root@pam"
  pm_password = var.pm_password
  pm_tls_insecure = true  # Only if you're not using valid TLS
}

