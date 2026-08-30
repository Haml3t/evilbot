variable "proxmox_api_token" {
  description = "Proxmox API token in format 'user@realm!tokenid=secret'"
  type        = string
  sensitive   = true
}

variable "vm_id" {
  description = "VMID for the new container (must be unique on evilbot)"
  type        = number
  default     = 500
}

variable "hostname" {
  description = "Container hostname"
  type        = string
  default     = "inferbot"
}

variable "ip_address" {
  description = "IPv4 address in CIDR notation (e.g. '192.168.0.223/24') or 'dhcp'"
  type        = string
  default     = "dhcp"
}

variable "cpu_cores" {
  description = "Number of CPU cores"
  type        = number
  default     = 2
}

variable "memory_mb" {
  description = "RAM in MB — 2048 is sufficient for Nomad server + FastAPI proxy"
  type        = number
  default     = 2048
}

variable "disk_storage" {
  description = "Proxmox storage ID for the root disk"
  type        = string
  default     = "local-lvm"
}

variable "disk_size_gb" {
  description = "Root disk size in GB"
  type        = number
  default     = 16
}

variable "template_file_id" {
  description = "CT template to clone from (e.g. 'local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst')"
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key to inject into root's authorized_keys"
  type        = string
}

# Declared but intentionally UNREFERENCED — see the pool_id comment block in main.tf.
# CT 500 is not currently in the claudebots pool, and pool_id is ForceNew, so wiring
# this up before moving the container into the pool would destroy it.
variable "pool_id" {
  description = "Proxmox pool the container should belong to. Not yet wired into main.tf — see the pool_id note there before using."
  type        = string
  default     = "claudebots"
}

variable "dns_domain" {
  description = "Search domain for the container (matches the live hand-set value)"
  type        = string
  default     = "local"
}

variable "dns_servers" {
  description = "DNS servers for the container (matches the live hand-set values)"
  type        = list(string)
  default     = ["8.8.8.8", "1.1.1.1"]
}
