output "vm_id" {
  description = "VMID of the created container"
  value       = proxmox_virtual_environment_container.hermesbot.vm_id
}

output "hostname" {
  description = "Hostname of the created container"
  value       = proxmox_virtual_environment_container.hermesbot.initialization[0].hostname
}

output "ip_address" {
  description = "Configured IP address"
  value       = var.ip_address
}

output "pool_id" {
  description = "Proxmox pool the container was created in"
  value       = var.pool_id
}
