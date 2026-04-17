###############################################################################
# Spoke2 DC Module Outputs
###############################################################################

output "dc_vm_id" {
  description = "Domain Controller VM resource ID"
  value       = azurerm_windows_virtual_machine.dc.id
}

output "dc_private_ip" {
  description = "Domain Controller private IP (for User-ID Agent config in PAN-OS)"
  value       = azurerm_network_interface.dc.private_ip_address
}

output "dc_vm_name" {
  description = "Domain Controller VM name"
  value       = azurerm_windows_virtual_machine.dc.name
}

output "bastion_public_ip" {
  description = "Azure Bastion public IP - use Azure Portal Bastion to RDP to DC"
  value       = azurerm_public_ip.bastion.ip_address
}

output "bastion_host_id" {
  description = "Azure Bastion host resource ID"
  value       = azurerm_bastion_host.spoke2.id
}

output "bastion_dns_name" {
  description = "Azure Bastion DNS name"
  value       = azurerm_bastion_host.spoke2.dns_name
}
