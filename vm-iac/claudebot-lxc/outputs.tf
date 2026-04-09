output "vm_id" {
  description = "VMID of the created container"
  value       = proxmox_virtual_environment_container.claudebot.vm_id
}

output "hostname" {
  description = "Hostname of the created container"
  value       = proxmox_virtual_environment_container.claudebot.initialization[0].hostname
}

output "ip_address" {
  description = "Configured IP address"
  value       = var.ip_address
}
