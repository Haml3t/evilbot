output "container_id" {
  description = "VMID of the created container"
  value       = proxmox_virtual_environment_container.hindsight.vm_id
}

output "hostname" {
  description = "Hostname of the created container"
  value       = proxmox_virtual_environment_container.hindsight.initialization[0].hostname
}
