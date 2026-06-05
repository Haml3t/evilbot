variable "proxmox_api_token" {
  description = "Proxmox API token in format 'user@realm!tokenid=secret'"
  type        = string
  sensitive   = true
}

variable "vm_id" {
  description = "VMID for the new container (must be unique on evilbot; 301+ recommended for devboxes)"
  type        = number
}

variable "hostname" {
  description = "Container hostname (e.g. 'devbox-1')"
  type        = string
}

variable "cpu_cores" {
  description = "Number of CPU cores"
  type        = number
  default     = 2
}

variable "memory_mb" {
  description = "RAM in MB"
  type        = number
  default     = 4096
}

variable "disk_storage" {
  description = "Proxmox storage ID for root disk"
  type        = string
  default     = "local-lvm"
}

variable "disk_size_gb" {
  description = "Root disk size in GB"
  type        = number
  default     = 32
}

variable "template_file_id" {
  description = "CT template to clone from (e.g. 'local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst')"
  type        = string
  default     = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
}

variable "ssh_public_key" {
  description = "SSH public key to inject into root's authorized_keys"
  type        = string
}
