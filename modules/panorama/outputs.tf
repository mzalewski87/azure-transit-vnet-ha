###############################################################################
# Panorama Module Outputs
###############################################################################

output "panorama_vm_id" {
  description = "Panorama VM resource ID"
  value       = azurerm_linux_virtual_machine.panorama.id
}

output "panorama_private_ip" {
  description = "Panorama private IP address (used in FW bootstrap init-cfg)"
  value       = azurerm_network_interface.panorama.private_ip_address
}

output "panorama_public_ip" {
  description = "Panorama management public IP - use for HTTPS GUI and SSH access"
  value       = azurerm_public_ip.panorama.ip_address
}

output "panorama_public_ip_id" {
  description = "Panorama public IP resource ID"
  value       = azurerm_public_ip.panorama.id
}
