###############################################################################
# Networking Module
# Palo Alto Transit VNet – Reference Architecture (PANW Azure Transit VNet Guide)
#
# VNet topology (per PANW reference architecture):
#
#   Management VNet (10.255.0.0/16)              ← Panorama + Bastion
#     snet-management:   10.255.0.0/24           ← Panorama: 10.255.0.4/5
#     AzureBastionSubnet: 10.255.1.0/26          ← Single Bastion for ALL VNets
#
#   Transit Hub VNet (10.110.0.0/16)             ← VM-Series HA pair
#     snet-mgmt:    10.110.255.0/24              ← FW eth0 (management)
#     snet-public:  10.110.129.0/24              ← FW eth1/1 (untrust, internet)
#     snet-private: 10.110.0.0/24               ← FW eth1/2 (trust, internal)
#     snet-ha:      10.110.128.0/24              ← FW eth1/3 (HA2 sync)
#
#   App1 VNet (10.112.0.0/16)                   ← Application workloads
#     snet-workload: 10.112.0.0/24
#
#   App2 VNet (10.113.0.0/16)                   ← Windows DC / additional workloads
#     snet-workload: 10.113.0.0/24
#
# VNet Peerings:
#   Management ↔ Transit Hub  (Panorama → FW management)
#   Management ↔ App1         (Bastion → App1 VMs)
#   Management ↔ App2         (Bastion → App2 VMs)
#   Transit Hub ↔ App1        (UDR traffic)
#   Transit Hub ↔ App2        (UDR traffic)
#
# Key design decisions:
#   - Panorama in separate Management VNet (as per PANW reference)
#   - Single Bastion (Standard) in Management VNet reaches ALL peered VNets
#   - No public IPs on FW/Panorama – Bastion tunnel for HTTPS management
#   - NAT Gateway in both Management VNet (Panorama license) and Transit mgmt (FW license)
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
# Locals – subnet CIDRs from VNet address spaces
###############################################################################
locals {
  # Management VNet subnets
  mgmt_vnet_panorama_cidr = cidrsubnet(var.management_vnet_address_space, 8, 0)  # 10.255.0.0/24
  mgmt_vnet_bastion_cidr  = cidrsubnet(var.management_vnet_address_space, 10, 4) # 10.255.1.0/26

  # Transit Hub VNet subnets (matching PANW reference IP scheme where transit = 10.110.0.0/16)
  transit_mgmt_cidr    = cidrsubnet(var.transit_vnet_address_space, 8, 255) # x.x.255.0/24 – management
  transit_public_cidr  = cidrsubnet(var.transit_vnet_address_space, 8, 129) # x.x.129.0/24 – public (untrust)
  transit_private_cidr = cidrsubnet(var.transit_vnet_address_space, 8, 0)   # x.x.0.0/24   – private (trust)
  transit_ha_cidr      = cidrsubnet(var.transit_vnet_address_space, 8, 128) # x.x.128.0/24 – HA2

  # App VNet subnets
  app1_workload_cidr = cidrsubnet(var.app1_vnet_address_space, 8, 0) # 10.112.0.0/24
  app2_workload_cidr = cidrsubnet(var.app2_vnet_address_space, 8, 0) # 10.113.0.0/24
}

###############################################################################
# Management VNet
# Hosts Panorama (primary + optional secondary) and Azure Bastion
###############################################################################

resource "azurerm_virtual_network" "management" {
  name                = "vnet-management"
  location            = var.location
  resource_group_name = var.hub_resource_group_name
  address_space       = [var.management_vnet_address_space]
  tags                = var.tags
}

# Panorama subnet
resource "azurerm_subnet" "management_panorama" {
  name                 = "snet-management"
  resource_group_name  = var.hub_resource_group_name
  virtual_network_name = azurerm_virtual_network.management.name
  address_prefixes     = [local.mgmt_vnet_panorama_cidr]
  service_endpoints    = ["Microsoft.Storage"]
}

# Azure Bastion subnet (required name: AzureBastionSubnet, min /26)
resource "azurerm_subnet" "management_bastion" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = var.hub_resource_group_name
  virtual_network_name = azurerm_virtual_network.management.name
  address_prefixes     = [local.mgmt_vnet_bastion_cidr]
}

###############################################################################
# Management VNet NSG (for Panorama subnet)
# Inbound: SSH + HTTPS from Bastion subnet only
# Outbound: all (license activation, content updates, etc.)
###############################################################################
resource "azurerm_network_security_group" "management_panorama" {
  name                = "nsg-management-panorama"
  location            = var.location
  resource_group_name = var.hub_resource_group_name
  tags                = var.tags

  # SSH from Bastion
  security_rule {
    name                       = "Allow-SSH-From-Bastion"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = local.mgmt_vnet_bastion_cidr
    destination_address_prefix = "*"
  }

  # HTTPS from Bastion (GUI, panos Terraform provider via Bastion tunnel)
  security_rule {
    name                       = "Allow-HTTPS-From-Bastion"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = local.mgmt_vnet_bastion_cidr
    destination_address_prefix = "*"
  }

  # Panorama ↔ FW management (3978/TCP, 28443/TCP HA, PAN-OS control plane)
  security_rule {
    name                       = "Allow-PanoramaFW-Peered"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["3978", "28443", "443"]
    source_address_prefix      = var.transit_vnet_address_space
    destination_address_prefix = "*"
  }

  # Allow all internal within Management VNet (HA between dual Panorama if deployed)
  security_rule {
    name                       = "Allow-VNet-Internal"
    priority                   = 130
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "Deny-All-Inbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  # Allow all outbound (license activation, content updates, Palo Alto cloud services)
  security_rule {
    name                       = "Allow-All-Outbound"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "management_panorama" {
  subnet_id                 = azurerm_subnet.management_panorama.id
  network_security_group_id = azurerm_network_security_group.management_panorama.id
}

###############################################################################
# Azure Bastion NSG (required rules for Azure Bastion Standard)
###############################################################################
resource "azurerm_network_security_group" "management_bastion" {
  name                = "nsg-management-bastion"
  location            = var.location
  resource_group_name = var.hub_resource_group_name
  tags                = var.tags

  security_rule {
    name                       = "Allow-HTTPS-Inbound-Internet"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-GatewayManager"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "GatewayManager"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-AzureLoadBalancer"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-BastionHostCommunication"
    priority                   = 130
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_ranges    = ["8080", "5701"]
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "Allow-RDP-SSH-HTTPS-Outbound"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["22", "3389", "443"]
    source_address_prefix      = "*"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "Allow-AzureCloud-Outbound"
    priority                   = 110
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "AzureCloud"
  }

  security_rule {
    name                       = "Allow-BastionHostCommunication-Outbound"
    priority                   = 120
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_ranges    = ["8080", "5701"]
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "Allow-HTTP-Outbound"
    priority                   = 130
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "Internet"
  }
}

resource "azurerm_subnet_network_security_group_association" "management_bastion" {
  subnet_id                 = azurerm_subnet.management_bastion.id
  network_security_group_id = azurerm_network_security_group.management_bastion.id
}

###############################################################################
# Azure Bastion (Standard – reaches VMs in ALL peered VNets)
# Standard tier required for: Bastion tunnel (--target-resource-id),
#   IpConnect (SSH to private IP), cross-VNet access via peering
###############################################################################
resource "azurerm_public_ip" "bastion" {
  name                = "pip-bastion-management"
  location            = var.location
  resource_group_name = var.hub_resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  tags                = var.tags
}

resource "azurerm_bastion_host" "management" {
  name                = "bastion-management"
  location            = var.location
  resource_group_name = var.hub_resource_group_name
  sku                 = "Standard"
  tunneling_enabled   = true   # Required for: az network bastion tunnel --target-resource-id
  ip_connect_enabled  = true   # Required for: az network bastion ssh --target-ip-address
  tags                = var.tags

  ip_configuration {
    name                 = "ipconfig-bastion"
    subnet_id            = azurerm_subnet.management_bastion.id
    public_ip_address_id = azurerm_public_ip.bastion.id
  }
}

###############################################################################
# NAT Gateway – Management VNet (Panorama outbound: license, updates)
###############################################################################
resource "azurerm_public_ip" "nat_gateway_management" {
  name                = "pip-nat-gateway-management"
  location            = var.location
  resource_group_name = var.hub_resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway" "management" {
  name                    = "natgw-management"
  location                = var.location
  resource_group_name     = var.hub_resource_group_name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10
  tags                    = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "management" {
  nat_gateway_id       = azurerm_nat_gateway.management.id
  public_ip_address_id = azurerm_public_ip.nat_gateway_management.id
}

resource "azurerm_subnet_nat_gateway_association" "management_panorama" {
  subnet_id      = azurerm_subnet.management_panorama.id
  nat_gateway_id = azurerm_nat_gateway.management.id
}

###############################################################################
# Transit (Hub) VNet
# Hosts VM-Series HA pair (FW1 Active + FW2 Passive)
###############################################################################

resource "azurerm_virtual_network" "transit" {
  name                = "vnet-transit-hub"
  location            = var.location
  resource_group_name = var.hub_resource_group_name
  address_space       = [var.transit_vnet_address_space]
  tags                = var.tags
}

# Management subnet – FW eth0 (mgmt interface)
# service_endpoints: Microsoft.Storage for bootstrap SA (Azure Policy compliance)
resource "azurerm_subnet" "transit_mgmt" {
  name                 = "snet-mgmt"
  resource_group_name  = var.hub_resource_group_name
  virtual_network_name = azurerm_virtual_network.transit.name
  address_prefixes     = [local.transit_mgmt_cidr]
  service_endpoints    = ["Microsoft.Storage"]
}

# Public subnet – FW eth1/1 (faces internet, connected to External LB)
resource "azurerm_subnet" "transit_public" {
  name                 = "snet-public"
  resource_group_name  = var.hub_resource_group_name
  virtual_network_name = azurerm_virtual_network.transit.name
  address_prefixes     = [local.transit_public_cidr]
}

# Private subnet – FW eth1/2 (faces internal/spoke networks, Internal LB)
resource "azurerm_subnet" "transit_private" {
  name                 = "snet-private"
  resource_group_name  = var.hub_resource_group_name
  virtual_network_name = azurerm_virtual_network.transit.name
  address_prefixes     = [local.transit_private_cidr]
}

# HA subnet – FW eth1/3 (HA2 data synchronisation link)
resource "azurerm_subnet" "transit_ha" {
  name                 = "snet-ha"
  resource_group_name  = var.hub_resource_group_name
  virtual_network_name = azurerm_virtual_network.transit.name
  address_prefixes     = [local.transit_ha_cidr]
}

###############################################################################
# Transit VNet NSGs
###############################################################################

# Management NSG – FW eth0
resource "azurerm_network_security_group" "transit_mgmt" {
  name                = "nsg-transit-mgmt"
  location            = var.location
  resource_group_name = var.hub_resource_group_name
  tags                = var.tags

  # SSH/HTTPS from Management VNet (Bastion tunnel + direct Panorama)
  security_rule {
    name                       = "Allow-SSH-From-Management-VNet"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.management_vnet_address_space
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-HTTPS-From-Management-VNet"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = var.management_vnet_address_space
    destination_address_prefix = "*"
  }

  # HA1 heartbeat between FW peers (within same mgmt subnet)
  security_rule {
    name                       = "Allow-HA1-Internal"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = local.transit_mgmt_cidr
    destination_address_prefix = local.transit_mgmt_cidr
  }

  security_rule {
    name                       = "Deny-All-Inbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  # Allow all outbound (license activation, content/threat updates, WildFire, etc.)
  security_rule {
    name                       = "Allow-All-Outbound-Internet"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "Internet"
  }

  security_rule {
    name                       = "Allow-VNet-Outbound"
    priority                   = 110
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "VirtualNetwork"
  }
}

# Public (Untrust) NSG – PAN-OS inspects all traffic
resource "azurerm_network_security_group" "transit_public" {
  name                = "nsg-transit-public"
  location            = var.location
  resource_group_name = var.hub_resource_group_name
  tags                = var.tags

  security_rule {
    name                       = "Allow-All-Inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-All-Outbound"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

# Private (Trust) NSG – PAN-OS enforces security policy
resource "azurerm_network_security_group" "transit_private" {
  name                = "nsg-transit-private"
  location            = var.location
  resource_group_name = var.hub_resource_group_name
  tags                = var.tags

  security_rule {
    name                       = "Allow-All-Inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-All-Outbound"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

# HA NSG – only HA2 sync between FW peers
resource "azurerm_network_security_group" "transit_ha" {
  name                = "nsg-transit-ha"
  location            = var.location
  resource_group_name = var.hub_resource_group_name
  tags                = var.tags

  security_rule {
    name                       = "Allow-HA2-Inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = local.transit_ha_cidr
    destination_address_prefix = local.transit_ha_cidr
  }

  security_rule {
    name                       = "Allow-HA2-Outbound"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = local.transit_ha_cidr
    destination_address_prefix = local.transit_ha_cidr
  }

  security_rule {
    name                       = "Deny-All-Inbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

###############################################################################
# NSG → Subnet Associations (Transit VNet)
###############################################################################

resource "azurerm_subnet_network_security_group_association" "transit_mgmt" {
  subnet_id                 = azurerm_subnet.transit_mgmt.id
  network_security_group_id = azurerm_network_security_group.transit_mgmt.id
}

resource "azurerm_subnet_network_security_group_association" "transit_public" {
  subnet_id                 = azurerm_subnet.transit_public.id
  network_security_group_id = azurerm_network_security_group.transit_public.id
}

resource "azurerm_subnet_network_security_group_association" "transit_private" {
  subnet_id                 = azurerm_subnet.transit_private.id
  network_security_group_id = azurerm_network_security_group.transit_private.id
}

resource "azurerm_subnet_network_security_group_association" "transit_ha" {
  subnet_id                 = azurerm_subnet.transit_ha.id
  network_security_group_id = azurerm_network_security_group.transit_ha.id
}

###############################################################################
# Public IP – External Load Balancer (inbound application traffic via AFD)
###############################################################################
resource "azurerm_public_ip" "external_lb" {
  name                = "pip-external-lb"
  location            = var.location
  resource_group_name = var.hub_resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  tags                = var.tags
}

###############################################################################
# NAT Gateway – Transit snet-mgmt (FW eth0 outbound: license, updates)
###############################################################################
resource "azurerm_public_ip" "nat_gateway_transit_mgmt" {
  name                = "pip-nat-gateway-transit-mgmt"
  location            = var.location
  resource_group_name = var.hub_resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway" "transit_mgmt" {
  name                    = "natgw-transit-mgmt"
  location                = var.location
  resource_group_name     = var.hub_resource_group_name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10
  tags                    = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "transit_mgmt" {
  nat_gateway_id       = azurerm_nat_gateway.transit_mgmt.id
  public_ip_address_id = azurerm_public_ip.nat_gateway_transit_mgmt.id
}

resource "azurerm_subnet_nat_gateway_association" "transit_mgmt" {
  subnet_id      = azurerm_subnet.transit_mgmt.id
  nat_gateway_id = azurerm_nat_gateway.transit_mgmt.id
}

###############################################################################
# App1 VNet & Subnets (Application workloads)
###############################################################################

resource "azurerm_virtual_network" "app1" {
  provider            = azurerm.spoke1
  name                = "vnet-app1"
  location            = var.location
  resource_group_name = var.app1_resource_group_name
  address_space       = [var.app1_vnet_address_space]
  tags                = var.tags
}

resource "azurerm_subnet" "app1_workload" {
  provider             = azurerm.spoke1
  name                 = "snet-workload"
  resource_group_name  = var.app1_resource_group_name
  virtual_network_name = azurerm_virtual_network.app1.name
  address_prefixes     = [local.app1_workload_cidr]
}

# App1 Workload NSG
resource "azurerm_network_security_group" "app1_workload" {
  provider            = azurerm.spoke1
  name                = "nsg-app1-workload"
  location            = var.location
  resource_group_name = var.app1_resource_group_name
  tags                = var.tags

  security_rule {
    name                       = "Allow-HTTP-From-Trust"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = local.transit_private_cidr
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-HTTPS-From-Trust"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = local.transit_private_cidr
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-SSH-From-Management"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.management_vnet_address_space
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Deny-All-Inbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "app1_workload" {
  provider                  = azurerm.spoke1
  subnet_id                 = azurerm_subnet.app1_workload.id
  network_security_group_id = azurerm_network_security_group.app1_workload.id
}

###############################################################################
# App2 VNet & Subnets (Windows DC / additional workloads)
###############################################################################

resource "azurerm_virtual_network" "app2" {
  provider            = azurerm.spoke2
  name                = "vnet-app2"
  location            = var.location
  resource_group_name = var.app2_resource_group_name
  address_space       = [var.app2_vnet_address_space]
  tags                = var.tags
}

resource "azurerm_subnet" "app2_workload" {
  provider             = azurerm.spoke2
  name                 = "snet-workload"
  resource_group_name  = var.app2_resource_group_name
  virtual_network_name = azurerm_virtual_network.app2.name
  address_prefixes     = [local.app2_workload_cidr]
}

# App2 Workload NSG
resource "azurerm_network_security_group" "app2_workload" {
  provider            = azurerm.spoke2
  name                = "nsg-app2-workload"
  location            = var.location
  resource_group_name = var.app2_resource_group_name
  tags                = var.tags

  security_rule {
    name                       = "Allow-RDP-From-Management"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3389"
    source_address_prefix      = var.management_vnet_address_space
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-Domain-From-Trust"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = local.transit_private_cidr
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-Domain-From-App1"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = var.app1_vnet_address_space
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Deny-All-Inbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "app2_workload" {
  provider                  = azurerm.spoke2
  subnet_id                 = azurerm_subnet.app2_workload.id
  network_security_group_id = azurerm_network_security_group.app2_workload.id
}

###############################################################################
# VNet Peerings
# Management VNet ↔ Transit Hub  (Panorama → FW communication)
# Management VNet ↔ App1         (Bastion reaches App1 VMs)
# Management VNet ↔ App2         (Bastion reaches App2/DC VMs)
# Transit Hub ↔ App1             (UDR: app traffic through FW)
# Transit Hub ↔ App2             (UDR: app traffic through FW)
###############################################################################

# Management ↔ Transit Hub
resource "azurerm_virtual_network_peering" "management_to_transit" {
  name                         = "peer-management-to-transit"
  resource_group_name          = var.hub_resource_group_name
  virtual_network_name         = azurerm_virtual_network.management.name
  remote_virtual_network_id    = azurerm_virtual_network.transit.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false
}

resource "azurerm_virtual_network_peering" "transit_to_management" {
  name                         = "peer-transit-to-management"
  resource_group_name          = var.hub_resource_group_name
  virtual_network_name         = azurerm_virtual_network.transit.name
  remote_virtual_network_id    = azurerm_virtual_network.management.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false
}

# Management ↔ App1
resource "azurerm_virtual_network_peering" "management_to_app1" {
  name                         = "peer-management-to-app1"
  resource_group_name          = var.hub_resource_group_name
  virtual_network_name         = azurerm_virtual_network.management.name
  remote_virtual_network_id    = azurerm_virtual_network.app1.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false
}

resource "azurerm_virtual_network_peering" "app1_to_management" {
  provider                     = azurerm.spoke1
  name                         = "peer-app1-to-management"
  resource_group_name          = var.app1_resource_group_name
  virtual_network_name         = azurerm_virtual_network.app1.name
  remote_virtual_network_id    = azurerm_virtual_network.management.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false

  depends_on = [
    azurerm_subnet.management_panorama,
    azurerm_subnet.management_bastion,
  ]
}

# Management ↔ App2
resource "azurerm_virtual_network_peering" "management_to_app2" {
  name                         = "peer-management-to-app2"
  resource_group_name          = var.hub_resource_group_name
  virtual_network_name         = azurerm_virtual_network.management.name
  remote_virtual_network_id    = azurerm_virtual_network.app2.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false
}

resource "azurerm_virtual_network_peering" "app2_to_management" {
  provider                     = azurerm.spoke2
  name                         = "peer-app2-to-management"
  resource_group_name          = var.app2_resource_group_name
  virtual_network_name         = azurerm_virtual_network.app2.name
  remote_virtual_network_id    = azurerm_virtual_network.management.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false

  depends_on = [
    azurerm_subnet.management_panorama,
    azurerm_subnet.management_bastion,
  ]
}

# Transit Hub ↔ App1
resource "azurerm_virtual_network_peering" "transit_to_app1" {
  name                         = "peer-transit-to-app1"
  resource_group_name          = var.hub_resource_group_name
  virtual_network_name         = azurerm_virtual_network.transit.name
  remote_virtual_network_id    = azurerm_virtual_network.app1.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false
}

resource "azurerm_virtual_network_peering" "app1_to_transit" {
  provider                     = azurerm.spoke1
  name                         = "peer-app1-to-transit"
  resource_group_name          = var.app1_resource_group_name
  virtual_network_name         = azurerm_virtual_network.app1.name
  remote_virtual_network_id    = azurerm_virtual_network.transit.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false

  depends_on = [
    azurerm_subnet.transit_mgmt,
    azurerm_subnet.transit_public,
    azurerm_subnet.transit_private,
    azurerm_subnet.transit_ha,
  ]
}

# Transit Hub ↔ App2
resource "azurerm_virtual_network_peering" "transit_to_app2" {
  name                         = "peer-transit-to-app2"
  resource_group_name          = var.hub_resource_group_name
  virtual_network_name         = azurerm_virtual_network.transit.name
  remote_virtual_network_id    = azurerm_virtual_network.app2.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false
}

resource "azurerm_virtual_network_peering" "app2_to_transit" {
  provider                     = azurerm.spoke2
  name                         = "peer-app2-to-transit"
  resource_group_name          = var.app2_resource_group_name
  virtual_network_name         = azurerm_virtual_network.app2.name
  remote_virtual_network_id    = azurerm_virtual_network.transit.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false

  depends_on = [
    azurerm_subnet.transit_mgmt,
    azurerm_subnet.transit_public,
    azurerm_subnet.transit_private,
    azurerm_subnet.transit_ha,
  ]
}
