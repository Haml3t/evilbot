variable "pm_api_url"      { type = string }                 # e.g. https://192.168.1.145:8006/api2/json
variable "pm_user"         { type = string }                 # e.g. root@pam
variable "pm_password"     { type = string, sensitive = true }
variable "pm_tls_insecure" { type = bool   default = true }

variable "pm_node"         { type = string }                 # e.g. "evilbot"
variable "pm_pool"         { type = string default = null }  # optional

variable "vmid"            { type = number }                 # e.g. 100
variable "vm_name"         { type = string default = "evilbot-nas" }
variable "vm_cores"        { type = number default = 2 }
variable "vm_memory"       { type = number default = 8192 }  # MiB
variable "vm_disk_size"    { type = string default = "64G" }
variable "vm_storage"      { type = string }                 # e.g. "tank-vmdata"
variable "vm_bridge"       { type = string default = "vmbr0" }

variable "iso_storage"     { type = string }                 # e.g. "tank-iso"
variable "iso_file"        { type = string }                 # e.g. "ubuntu-24.04.2-live-server-amd64.iso"

variable "ci_user"         { type = string default = "david" }
variable "david_ssh_pubkey"{ type = string }                 # ssh-ed25519 AAAA...
