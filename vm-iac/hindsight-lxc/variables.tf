variable "proxmox_api_token" {
  description = "Proxmox API token in format 'user@realm!tokenid=secret' — use hermes-lxc@pve!lxc, scoped to pool 'hermesbots'"
  type        = string
  sensitive   = true
}

variable "vm_id" {
  description = "VMID for the new container (800 reserved for hindsight; next free slot after 700)"
  type        = number
  default     = 800
}

variable "hostname" {
  description = "Container hostname"
  type        = string
  default     = "hindsight"
}

variable "cpu_cores" {
  description = "Number of CPU cores"
  type        = number
  default     = 2
}

variable "memory_mb" {
  description = "RAM in MB — Hindsight's own docs call for 4096 min, 8192 recommended for production; 6144 split the difference for a personal deployment"
  type        = number
  default     = 6144
}

variable "disk_storage" {
  description = "Proxmox storage ID for root disk"
  type        = string
  default     = "local-lvm"
}

variable "disk_size_gb" {
  description = "Root disk size in GB — the Hindsight Docker image is ~9GB plus Postgres growth"
  type        = number
  default     = 24
}

variable "template_file_id" {
  description = "CT template to clone from"
  type        = string
  default     = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
}

variable "ssh_public_key" {
  description = "SSH public key to inject into root's authorized_keys — for INITIAL provisioning only; a dedicated unprivileged 'hermes' user + hermes-grant replaces root access afterward, matching every other guest in the fleet"
  type        = string
}
