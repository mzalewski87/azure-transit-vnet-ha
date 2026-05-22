###############################################################################
# AKS Network Module – Outputs
###############################################################################

output "resource_group_name" {
  description = "Resource group name for spoke3 / AKS resources"
  value       = azurerm_resource_group.aks.name
}

output "vnet_id" {
  description = "Spoke3 VNet resource ID"
  value       = azurerm_virtual_network.spoke3.id
}

output "vnet_name" {
  description = "Spoke3 VNet name"
  value       = azurerm_virtual_network.spoke3.name
}

output "aks_nodes_subnet_id" {
  description = "Subnet ID for AKS node pool"
  value       = azurerm_subnet.aks_nodes.id
}

output "aks_ilb_subnet_id" {
  description = "Subnet ID for AKS internal LB (ingress-nginx)"
  value       = azurerm_subnet.aks_ilb.id
}

output "aks_spoke_cidr" {
  description = "Spoke3 VNet CIDR (passed to Panorama AKS-Spoke3-CIDR address object)"
  value       = var.spoke3_vnet_address_space
}

output "aks_nodes_subnet_cidr" {
  description = "AKS nodes subnet CIDR"
  value       = var.aks_nodes_subnet_cidr
}
