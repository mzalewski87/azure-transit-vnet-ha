###############################################################################
# Panorama Module Outputs
###############################################################################

output "panorama_vm_id" {
  description = "Panorama VM resource ID (używany w az network bastion tunnel --target-resource-id)"
  value       = azurerm_linux_virtual_machine.panorama.id
}

output "panorama_private_ip" {
  description = "Panorama private IP (FW bootstrap init-cfg panorama-server + Bastion tunnel target)"
  value       = azurerm_network_interface.panorama.private_ip_address
}
