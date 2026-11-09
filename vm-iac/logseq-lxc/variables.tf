variable "proxmox_api_token" {
  description = "Proxmox API token in format 'user@realm!tokenid=secret' — use hermes-lxc@pve!lxc, scoped to pool 'hermesbots'"
  type        = string
  sensitive   = true
}

variable "vm_id" {
  description = "VMID for the new container (810 = logseq, beside 800 hindsight)"
  type        = number
  default     = 810
}

variable "hostname" {
  description = "Container hostname"
  type        = string
  default     = "logseq"
}

variable "cpu_cores" {
  description = "Number of CPU cores"
  type        = number
  default     = 2
}

variable "memory_mb" {
  description = "RAM in MB — Node CLI + db-worker-node; 4 GB so a full-graph sqlite import (sandbox copy) fits"
  type        = number
  default     = 4096
}

variable "disk_storage" {
  description = "Proxmox storage ID for root disk"
  type        = string
  default     = "local-lvm"
}

variable "disk_size_gb" {
  description = "Root disk size in GB — OS + Node + graph + local graph backups"
  type        = number
  default     = 12
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
