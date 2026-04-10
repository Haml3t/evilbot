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

variable "ci_user" {
  description = "Initial user created by cloud-init"
  type        = string
  default     = "david"
}

variable "ssh_public_key" {
  description = "SSH public key injected at provision time"
  type        = string
}
