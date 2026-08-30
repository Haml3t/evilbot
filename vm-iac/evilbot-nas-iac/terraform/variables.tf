variable "proxmox_api_token" {
  description = "Proxmox API token — terraform-lxc@pve!lxc=<secret>"
  type        = string
  sensitive   = true
}

variable "vm_cores" {
  type    = number
  default = 2
}

variable "vm_memory" {
  description = "RAM in MB"
  type        = number
  default     = 8192
}

variable "vm_storage" {
  description = "Proxmox storage ID for the boot disk (e.g. 'tank-vmdata')"
  type        = string
  default     = "tank-vmdata"
}

variable "vm_bridge" {
  type    = string
  default = "vmbr0"
}

variable "vm_mac_address" {
  description = <<-EOT
    MAC of the primary NIC, pinned to the live VM (verified 2026-08-30).
    This VM is DHCP with no guest agent; fleet/inventory.yaml records it at
    192.168.0.67. Letting Terraform generate a new MAC on recreate would change
    the DHCP lease and silently invalidate the documented IP.
  EOT
  type        = string
  default     = "BC:24:11:54:3C:26"
}

variable "ci_user" {
  description = "Initial user created by cloud-init"
  type        = string
  default     = "admin"
}

variable "ssh_public_key" {
  description = "SSH public key injected at provision time"
  type        = string
}
