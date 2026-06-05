output "vm_id" {
  description = "VMID of the created devbox container"
  value       = proxmox_virtual_environment_container.devbox.vm_id
}

output "hostname" {
  description = "Hostname of the devbox"
  value       = proxmox_virtual_environment_container.devbox.initialization[0].hostname
}

output "ssh_command" {
  description = "SSH command to connect (IP assigned by DHCP — run provision.sh to discover it)"
  value       = "ssh -J root@192.168.1.145 root@<devbox-ip>"
}
