variable "proxmox_api_token" {
  description = "Proxmox API token in format 'user@realm!tokenid=secret'"
  type        = string
  sensitive   = true
}

variable "vm_id" {
  description = "VMID for the new container (must be unique on evilbot)"
  type        = number
  default     = 700
}

variable "hostname" {
  description = "Container hostname"
  type        = string
  default     = "hermesbot"
}

variable "pool_id" {
  description = "Proxmox pool. Must be 'claudebots' — the LXC API token is scoped to /pool/claudebots and returns 403 outside it."
  type        = string
  default     = "claudebots"
}

variable "ip_address" {
  description = "IPv4 in CIDR notation (e.g. '192.168.0.225/24') or 'dhcp'. Static keeps firewall rules stable; if static, add it to the network-migration checklist in CLAUDE.md alongside inferbot (.223) and opsbot (.224)."
  type        = string
  default     = "192.168.0.225/24"
}

variable "cpu_cores" {
  description = "CPU cores. 4 — the gateway, a browser backend, and one or two subagents are not a 2-core workload."
  type        = number
  default     = 4
}

variable "memory_mb" {
  description = "RAM in MB. 8192 — Hermes' .[all] extra pulls Playwright/Chromium; 2GB (inferbot-sized) is not enough."
  type        = number
  default     = 8192
}

variable "swap_mb" {
  description = "Swap in MB"
  type        = number
  default     = 512
}

variable "disk_storage" {
  description = "Proxmox storage ID for the root disk. Use local-lvm (782G free); 'local' is at 77% with ~17G free."
  type        = string
  default     = "local-lvm"
}

variable "disk_size_gb" {
  description = "Root disk in GB. 40 covers the install, Chromium, the session DB, and skill/memory growth."
  type        = number
  default     = 40
}

variable "template_file_id" {
  description = "CT template to clone from"
  type        = string
  default     = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
}

variable "ssh_public_key" {
  description = "SSH public key injected into root's authorized_keys. Use a key you control for bootstrap; hermesbot generates its OWN keypair for outbound fleet access (Phase 3) — do not reuse claudebot's."
  type        = string
}
