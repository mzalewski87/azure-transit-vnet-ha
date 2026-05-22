###############################################################################
# AKS Network Module
#
# Creates a new spoke VNet (spoke3) for AKS, peers it bidirectionally with
# the existing Transit Hub VNet, and installs a UDR that forces all AKS
# egress through the existing Internal LB (which fronts the VM-Series FWs).
#
# Pattern mirrors the existing spoke1 / spoke2 wiring in modules/networking
# and modules/routing — same peering settings (allow_forwarded_traffic),
# same UDR next-hop (transit Internal LB), same BGP-disabled route table.
#
# All resources live in the hub subscription; this module assumes a single
# default `azurerm` provider. For multi-subscription deployments, add
# provider aliases — out of scope for the initial AKS demo.
###############################################################################

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
  }
}

###############################################################################
# Resource group
###############################################################################

resource "azurerm_resource_group" "aks" {
  name     = var.aks_resource_group_name
  location = var.location
  tags     = var.tags
}

###############################################################################
# Spoke3 VNet + subnets
###############################################################################

resource "azurerm_virtual_network" "spoke3" {
  name                = "vnet-app3-aks"
  location            = var.location
  resource_group_name = azurerm_resource_group.aks.name
  address_space       = [var.spoke3_vnet_address_space]
  tags                = var.tags
}

# AKS node pool subnet. Azure CNI Overlay uses VNet IPs only for nodes —
# pods are on a separate (non-VNet) pod_cidr — so a /24 is plenty.
resource "azurerm_subnet" "aks_nodes" {
  name                 = "snet-aks-nodes"
  resource_group_name  = azurerm_resource_group.aks.name
  virtual_network_name = azurerm_virtual_network.spoke3.name
  address_prefixes     = [var.aks_nodes_subnet_cidr]
}

# Subnet for the internal LoadBalancer that fronts ingress-nginx.
# Annotated on the helm_release with azure-load-balancer-internal-subnet=snet-aks-ilb
# so AKS provisions the LB frontend here, NOT in the node subnet.
resource "azurerm_subnet" "aks_ilb" {
  name                 = "snet-aks-ilb"
  resource_group_name  = azurerm_resource_group.aks.name
  virtual_network_name = azurerm_virtual_network.spoke3.name
  address_prefixes     = [var.aks_ilb_subnet_cidr]
}

###############################################################################
# VNet peering (bidirectional) Transit Hub ↔ Spoke3
#
# Settings mirror the existing transit↔app1 / transit↔app2 peerings:
#   allow_forwarded_traffic=true is required so FW-forwarded packets (after
#   inspection) can enter the spoke. allow_gateway_transit / use_remote_gateways
#   are false because there is no ExpressRoute / VPN gateway in the design.
###############################################################################

resource "azurerm_virtual_network_peering" "transit_to_spoke3" {
  name                         = "peer-transit-to-app3"
  resource_group_name          = var.transit_resource_group_name
  virtual_network_name         = var.transit_vnet_name
  remote_virtual_network_id    = azurerm_virtual_network.spoke3.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false
}

resource "azurerm_virtual_network_peering" "spoke3_to_transit" {
  name                         = "peer-app3-to-transit"
  resource_group_name          = azurerm_resource_group.aks.name
  virtual_network_name         = azurerm_virtual_network.spoke3.name
  remote_virtual_network_id    = var.transit_vnet_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false

  depends_on = [
    azurerm_subnet.aks_nodes,
    azurerm_subnet.aks_ilb,
  ]
}

###############################################################################
# UDR — default route 0.0.0.0/0 → transit Internal LB (next-hop is FW pair)
#
# Required by AKS `outbound_type=userDefinedRouting` mode. Without this UDR,
# AKS would refuse cluster creation (the API checks for a valid 0.0.0.0/0
# route on the node subnet before provisioning when UDR egress is requested).
#
# BGP propagation disabled so any future on-premises announcement cannot
# override the FW next-hop.
###############################################################################

resource "azurerm_route_table" "aks" {
  name                          = "rt-app3-aks"
  location                      = var.location
  resource_group_name           = azurerm_resource_group.aks.name
  bgp_route_propagation_enabled = false
  tags                          = var.tags
}

resource "azurerm_route" "aks_default" {
  name                   = "route-default-to-fw"
  resource_group_name    = azurerm_resource_group.aks.name
  route_table_name       = azurerm_route_table.aks.name
  address_prefix         = "0.0.0.0/0"
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = var.internal_lb_private_ip
}

resource "azurerm_subnet_route_table_association" "aks_nodes" {
  subnet_id      = azurerm_subnet.aks_nodes.id
  route_table_id = azurerm_route_table.aks.id
}

# Intentionally NOT associating the route table with snet-aks-ilb:
#   The ILB serves traffic that's already arrived from the FW via DNAT;
#   if we sent return traffic 0.0.0.0/0 back to the same FW we'd create a
#   loop. ILB return traffic uses Azure's system routes within the VNet,
#   which are correct without a UDR.
