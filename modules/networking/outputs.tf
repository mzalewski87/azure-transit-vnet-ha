###############################################################################
# Networking Module Outputs
###############################################################################

# Management VNet
output "management_vnet_id" {
  description = "Management VNet ID (Panorama VNet)"
  value       = azurerm_virtual_network.management.id
}

output "management_subnet_id" {
  description = "Management subnet ID (snet-management in Management VNet) – Panorama NIC"
  value       = azurerm_subnet.management_panorama.id
}

output "management_subnet_cidr" {
  description = "Management subnet CIDR (Panorama)"
  value       = azurerm_subnet.management_panorama.address_prefixes[0]
}

output "bastion_name" {
  description = "Azure Bastion name (in Management VNet)"
  value       = azurerm_bastion_host.management.name
}

output "bastion_resource_group" {
  description = "Resource group of Azure Bastion"
  value       = azurerm_bastion_host.management.resource_group_name
}

# Transit VNet
output "transit_vnet_id" {
  description = "Transit Hub VNet ID"
  value       = azurerm_virtual_network.transit.id
}

output "mgmt_subnet_id" {
  description = "Transit FW management subnet ID (snet-mgmt) – FW eth0"
  value       = azurerm_subnet.transit_mgmt.id
}

output "untrust_subnet_id" {
  description = "Transit public/untrust subnet ID (snet-public) – FW eth1/1"
  value       = azurerm_subnet.transit_public.id
}

output "trust_subnet_id" {
  description = "Transit private/trust subnet ID (snet-private) – FW eth1/2"
  value       = azurerm_subnet.transit_private.id
}

output "ha_subnet_id" {
  description = "Transit HA subnet ID (snet-ha) – FW eth1/3 HA2"
  value       = azurerm_subnet.transit_ha.id
}

# Public IPs
output "external_lb_public_ip_id" {
  description = "External Load Balancer public IP resource ID"
  value       = azurerm_public_ip.external_lb.id
}

output "external_lb_public_ip_address" {
  description = "External Load Balancer public IP address"
  value       = azurerm_public_ip.external_lb.ip_address
}

# App VNets
output "app1_workload_subnet_id" {
  description = "App1 workload subnet ID"
  value       = azurerm_subnet.app1_workload.id
}

output "app2_workload_subnet_id" {
  description = "App2 workload subnet ID"
  value       = azurerm_subnet.app2_workload.id
}

# Legacy aliases (backward compat with modules that use spoke1/spoke2 naming)
output "spoke1_workload_subnet_id" {
  description = "Alias for app1_workload_subnet_id"
  value       = azurerm_subnet.app1_workload.id
}

output "spoke2_workload_subnet_id" {
  description = "Alias for app2_workload_subnet_id"
  value       = azurerm_subnet.app2_workload.id
}
