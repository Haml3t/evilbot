output "vm_id" {
  description = "Proxmox VMID of the NAS VM."
  value       = proxmox_virtual_environment_vm.evilbot_nas.vm_id
}

output "vm_name" {
  description = "VM name as registered in Proxmox."
  value       = proxmox_virtual_environment_vm.evilbot_nas.name
}

output "node_name" {
  description = "Proxmox node hosting this VM."
  value       = proxmox_virtual_environment_vm.evilbot_nas.node_name
}

output "mac_address" {
  description = <<-EOT
    MAC of the primary NIC. This VM is DHCP and has no QEMU guest agent, so
    Terraform cannot report its IP. The MAC is the stable handle: find the
    current lease with `ip neigh | grep -i <mac>` on evilbot, or check the
    router's DHCP table. Recorded as 192.168.0.67 in fleet/inventory.yaml.
  EOT
  value       = try(proxmox_virtual_environment_vm.evilbot_nas.network_device[0].mac_address, null)
}

output "virtiofs_reminder" {
  description = "Post-apply manual step — virtiofs is not managed by this provider."
  value       = <<-EOT
    virtiofs0 (dirid=tankshare) is NOT managed by Terraform. After any recreate:
      ssh root@192.168.0.145 "qm set 100 --virtiofs0 dirid=tankshare,cache=auto"
    Verify with:
      ssh root@192.168.0.145 "qm config 100 | grep virtiofs"
    Without it the NAS boots with no /tank and Transmission fails silently.
  EOT
}
