variable "proxmox_api_token" {
  description = "Proxmox API token — terraform-lxc@pve!lxc=<secret>"
  type        = string
  sensitive   = true
}

variable "ssh_public_key" {
  description = "SSH public key injected into ubuntu user's authorized_keys"
  type        = string
}
