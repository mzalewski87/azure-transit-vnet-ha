###############################################################################
# EDL Server Module – Outputs
###############################################################################

output "private_ip" {
  description = "Private IP of the EDL nginx server (consumed by panos_panorama_edl source URL)"
  value       = azurerm_network_interface.edl.ip_configuration[0].private_ip_address
}

output "fqdn_edl_url" {
  description = "URL of the FQDN External Dynamic List served to Panorama"
  value       = "http://${azurerm_network_interface.edl.ip_configuration[0].private_ip_address}/edl/aks-egress-fqdn.txt"
}

output "ips_edl_url" {
  description = "URL of the IP External Dynamic List served to Panorama"
  value       = "http://${azurerm_network_interface.edl.ip_configuration[0].private_ip_address}/edl/aks-egress-ips.txt"
}

output "vm_id" {
  description = "EDL server VM resource ID"
  value       = azurerm_linux_virtual_machine.edl.id
}
