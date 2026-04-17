###############################################################################
# Routing Module
# User Defined Routes (UDR) for Spoke subnets
#
# Purpose:
#   Force all traffic from Spoke VNets through VM-Series firewalls
#   by setting the Internal LB frontend IP as the next-hop.
#
# Routes configured per spoke:
#   1. Default route (0.0.0.0/0) → Internal LB → outbound internet via FW
#   2. East-West route (to other spoke) → Internal LB → inter-spoke via FW
#
# BGP route propagation is disabled to prevent on-premises routes from
# overriding the UDR next-hop settings.
###############################################################################

terraform {
  required_providers {
    azurerm = {
      source                = "hashicorp/azurerm"
      configuration_aliases = [azurerm.spoke1, azurerm.spoke2]
    }
  }
}

###############################################################################
# Route Table for Spoke 1 Workload Subnet
###############################################################################

resource "azurerm_route_table" "spoke1" {
  provider                      = azurerm.spoke1
  name                          = "rt-spoke1-workload"
  location                      = var.location
  resource_group_name           = var.spoke1_resource_group_name
  bgp_route_propagation_enabled = false # Disable BGP to prevent route override
  tags                          = var.tags
}

# Default route: all internet-bound traffic → Internal LB → FW outbound inspection
resource "azurerm_route" "spoke1_default" {
  provider               = azurerm.spoke1
  name                   = "route-default-to-fw"
  resource_group_name    = var.spoke1_resource_group_name
  route_table_name       = azurerm_route_table.spoke1.name
  address_prefix         = "0.0.0.0/0"
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = var.internal_lb_private_ip
}

# East-West route: traffic to Spoke 2 → Internal LB → FW east-west inspection
resource "azurerm_route" "spoke1_to_spoke2" {
  provider               = azurerm.spoke1
  name                   = "route-to-spoke2"
  resource_group_name    = var.spoke1_resource_group_name
  route_table_name       = azurerm_route_table.spoke1.name
  address_prefix         = var.spoke2_vnet_address_space
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = var.internal_lb_private_ip
}

# Associate route table with Spoke 1 workload subnet
resource "azurerm_subnet_route_table_association" "spoke1_workload" {
  provider       = azurerm.spoke1
  subnet_id      = var.spoke1_workload_subnet_id
  route_table_id = azurerm_route_table.spoke1.id
}

###############################################################################
# Route Table for Spoke 2 Workload Subnet
###############################################################################

resource "azurerm_route_table" "spoke2" {
  provider                      = azurerm.spoke2
  name                          = "rt-spoke2-workload"
  location                      = var.location
  resource_group_name           = var.spoke2_resource_group_name
  bgp_route_propagation_enabled = false
  tags                          = var.tags
}

# Default route: all internet-bound traffic → Internal LB → FW outbound inspection
resource "azurerm_route" "spoke2_default" {
  provider               = azurerm.spoke2
  name                   = "route-default-to-fw"
  resource_group_name    = var.spoke2_resource_group_name
  route_table_name       = azurerm_route_table.spoke2.name
  address_prefix         = "0.0.0.0/0"
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = var.internal_lb_private_ip
}

# East-West route: traffic to Spoke 1 → Internal LB → FW east-west inspection
resource "azurerm_route" "spoke2_to_spoke1" {
  provider               = azurerm.spoke2
  name                   = "route-to-spoke1"
  resource_group_name    = var.spoke2_resource_group_name
  route_table_name       = azurerm_route_table.spoke2.name
  address_prefix         = var.spoke1_vnet_address_space
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = var.internal_lb_private_ip
}

# Associate route table with Spoke 2 workload subnet
resource "azurerm_subnet_route_table_association" "spoke2_workload" {
  provider       = azurerm.spoke2
  subnet_id      = var.spoke2_workload_subnet_id
  route_table_id = azurerm_route_table.spoke2.id
}
