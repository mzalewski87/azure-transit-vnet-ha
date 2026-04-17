###############################################################################
# Networking Module Outputs
###############################################################################

output "transit_vnet_id" {
  description = "Transit Hub VNet resource ID"
  value       = azurerm_virtual_network.transit.id
}

output "transit_vnet_name" {
  description = "Transit Hub VNet name"
  value       = azurerm_virtual_network.transit.name
}

output "mgmt_subnet_id" {
  description = "Management subnet ID"
  value       = azurerm_subnet.mgmt.id
}

output "untrust_subnet_id" {
  description = "Untrust subnet ID"
  value       = azurerm_subnet.untrust.id
}

output "trust_subnet_id" {
  description = "Trust subnet ID"
  value       = azurerm_subnet.trust.id
}

output "ha_subnet_id" {
  description = "HA subnet ID"
  value       = azurerm_subnet.ha.id
}

output "spoke1_vnet_id" {
  description = "Spoke 1 VNet resource ID"
  value       = azurerm_virtual_network.spoke1.id
}

output "spoke2_vnet_id" {
  description = "Spoke 2 VNet resource ID"
  value       = azurerm_virtual_network.spoke2.id
}

output "spoke1_workload_subnet_id" {
  description = "Spoke 1 workload subnet ID"
  value       = azurerm_subnet.spoke1_workload.id
}

output "spoke2_workload_subnet_id" {
  description = "Spoke 2 workload subnet ID"
  value       = azurerm_subnet.spoke2_workload.id
}

output "external_lb_public_ip_id" {
  description = "External Load Balancer public IP resource ID"
  value       = azurerm_public_ip.external_lb.id
}

output "external_lb_public_ip_address" {
  description = "External Load Balancer public IP address"
  value       = azurerm_public_ip.external_lb.ip_address
}

output "spoke2_bastion_subnet_id" {
  description = "AzureBastionSubnet ID in Spoke 2 VNet"
  value       = azurerm_subnet.spoke2_bastion.id
}

output "spoke2_bastion_subnet_cidr" {
  description = "AzureBastionSubnet CIDR in Spoke 2 VNet"
  value       = azurerm_subnet.spoke2_bastion.address_prefixes[0]
}

output "nat_gateway_public_ip" {
  description = "NAT Gateway public IP (wychodzaca komunikacja snet-mgmt - Panorama/FW updates)"
  value       = azurerm_public_ip.nat_gateway_mgmt.ip_address
}
