###############################################################################
# Spoke1 App Module Outputs
###############################################################################

output "apache_vm_id" {
  description = "Apache server VM resource ID"
  value       = azurerm_linux_virtual_machine.apache.id
}

output "apache_private_ip" {
  description = "Apache server private IP (DNAT target for PAN-OS NAT policy)"
  value       = azurerm_network_interface.apache.private_ip_address
}

output "apache_vm_name" {
  description = "Apache server VM name"
  value       = azurerm_linux_virtual_machine.apache.name
}
