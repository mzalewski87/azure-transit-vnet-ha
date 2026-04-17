###############################################################################
# Firewall Module Outputs
###############################################################################

output "fw1_vm_id" {
  description = "FW1 virtual machine resource ID"
  value       = azurerm_linux_virtual_machine.fw1.id
}

output "fw2_vm_id" {
  description = "FW2 virtual machine resource ID"
  value       = azurerm_linux_virtual_machine.fw2.id
}

output "fw1_mgmt_private_ip" {
  description = "FW1 management interface private IP"
  value       = azurerm_network_interface.fw1_mgmt.private_ip_address
}

output "fw2_mgmt_private_ip" {
  description = "FW2 management interface private IP"
  value       = azurerm_network_interface.fw2_mgmt.private_ip_address
}

output "fw1_untrust_private_ip" {
  description = "FW1 untrust interface private IP"
  value       = azurerm_network_interface.fw1_untrust.private_ip_address
}

output "fw2_untrust_private_ip" {
  description = "FW2 untrust interface private IP"
  value       = azurerm_network_interface.fw2_untrust.private_ip_address
}

output "fw1_trust_private_ip" {
  description = "FW1 trust interface private IP"
  value       = azurerm_network_interface.fw1_trust.private_ip_address
}

output "fw2_trust_private_ip" {
  description = "FW2 trust interface private IP"
  value       = azurerm_network_interface.fw2_trust.private_ip_address
}

output "fw1_ha_private_ip" {
  description = "FW1 HA2 interface private IP"
  value       = azurerm_network_interface.fw1_ha.private_ip_address
}

output "fw2_ha_private_ip" {
  description = "FW2 HA2 interface private IP"
  value       = azurerm_network_interface.fw2_ha.private_ip_address
}

output "availability_set_id" {
  description = "Availability Set resource ID"
  value       = azurerm_availability_set.fw_avset.id
}
