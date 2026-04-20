###############################################################################
# Spoke2 DC Module Outputs
###############################################################################

output "dc_vm_id" {
  description = "DC VM resource ID (for Bastion IpConnect)"
  value       = azurerm_windows_virtual_machine.dc.id
}

output "dc_private_ip" {
  description = "DC private IP address"
  value       = azurerm_network_interface.dc.private_ip_address
}
