###############################################################################
# Networking Module
# Transit Hub VNet, Spoke VNets, Subnets, NSGs, VNet Peerings, Public IPs
###############################################################################

terraform {
  required_providers {
    azurerm = {
      source                = "hashicorp/azurerm"
      configuration_aliases = [azurerm.spoke1, azurerm.spoke2]
    }
  }
}

#------------------------------------------------------------------------------
# Locals - compute subnet CIDRs from VNet address space
# Transit VNet /16 split into /24 subnets:
#   10.0.0.0/24 - Management
#   10.0.1.0/24 - Untrust (external)
#   10.0.2.0/24 - Trust (internal)
#   10.0.3.0/24 - HA (HA2 data sync)
#------------------------------------------------------------------------------
locals {
  mgmt_subnet_cidr    = cidrsubnet(var.transit_vnet_address_space, 8, 0) # 10.0.0.0/24
  untrust_subnet_cidr = cidrsubnet(var.transit_vnet_address_space, 8, 1) # 10.0.1.0/24
  trust_subnet_cidr   = cidrsubnet(var.transit_vnet_address_space, 8, 2) # 10.0.2.0/24
  ha_subnet_cidr      = cidrsubnet(var.transit_vnet_address_space, 8, 3) # 10.0.3.0/24

  # Hub AzureBastionSubnet: /26 minimum, using 10.0.4.0/26
  # cidrsubnet("10.0.0.0/16", 10, 16) = 10.0.4.0/26
  hub_bastion_subnet_cidr = cidrsubnet(var.transit_vnet_address_space, 10, 16) # 10.0.4.0/26

  spoke1_workload_cidr = cidrsubnet(var.spoke1_vnet_address_space, 8, 0) # 10.1.0.0/24
  spoke2_workload_cidr = cidrsubnet(var.spoke2_vnet_address_space, 8, 0) # 10.2.0.0/24
}

###############################################################################
# Transit (Hub) VNet
###############################################################################

resource "azurerm_virtual_network" "transit" {
  name                = "vnet-transit-hub"
  location            = var.location
  resource_group_name = var.hub_resource_group_name
  address_space       = [var.transit_vnet_address_space]
  tags                = var.tags
}

# Management subnet - PAN-OS management interfaces (eth0)
# service_endpoints: Microsoft.Storage needed for bootstrap SA network_rules (Azure Policy compliance)
resource "azurerm_subnet" "mgmt" {
  name                 = "snet-mgmt"
  resource_group_name  = var.hub_resource_group_name
  virtual_network_name = azurerm_virtual_network.transit.name
  address_prefixes     = [local.mgmt_subnet_cidr]
  service_endpoints    = ["Microsoft.Storage"]
}

# Untrust subnet - PAN-OS external interfaces (eth1) - faces Internet
resource "azurerm_subnet" "untrust" {
  name                 = "snet-untrust"
  resource_group_name  = var.hub_resource_group_name
  virtual_network_name = azurerm_virtual_network.transit.name
  address_prefixes     = [local.untrust_subnet_cidr]
}

# Trust subnet - PAN-OS internal interfaces (eth2) - faces internal/spoke networks
resource "azurerm_subnet" "trust" {
  name                 = "snet-trust"
  resource_group_name  = var.hub_resource_group_name
  virtual_network_name = azurerm_virtual_network.transit.name
  address_prefixes     = [local.trust_subnet_cidr]
}

# HA subnet - PAN-OS HA2 data sync link (eth3)
resource "azurerm_subnet" "ha" {
  name                 = "snet-ha"
  resource_group_name  = var.hub_resource_group_name
  virtual_network_name = azurerm_virtual_network.transit.name
  address_prefixes     = [local.ha_subnet_cidr]
}

###############################################################################
# Network Security Groups
###############################################################################

# Management NSG
# Dostęp SSH (22) i HTTPS (443) WYŁĄCZNIE z AzureBastionSubnet Huba (10.0.4.0/26)
# Brak publicznych IP na VM – żaden ruch z Internetu nie dociera do tej podsieci
resource "azurerm_network_security_group" "mgmt" {
  name                = "nsg-mgmt"
  location            = var.location
  resource_group_name = var.hub_resource_group_name
  tags                = var.tags

  # SSH – tylko z Hub Bastion subnet (admin az network bastion ssh / tunnel)
  security_rule {
    name                       = "Allow-SSH-From-HubBastion"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = local.hub_bastion_subnet_cidr # 10.0.4.0/26
    destination_address_prefix = "*"
  }

  # HTTPS GUI – tylko z Hub Bastion subnet (az network bastion tunnel port 443)
  security_rule {
    name                       = "Allow-HTTPS-From-HubBastion"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = local.hub_bastion_subnet_cidr # 10.0.4.0/26
    destination_address_prefix = "*"
  }

  # HA1 heartbeat – ruch między Panoramą i firewallami w tej samej podsieci
  security_rule {
    name                       = "Allow-HA1-MgmtSubnet-Internal"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = local.mgmt_subnet_cidr
    destination_address_prefix = local.mgmt_subnet_cidr
  }

  # Odmów całego pozostałego ruchu przychodzącego z Internetu
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

# Untrust NSG - allow all inbound (PAN-OS inspects and controls all traffic)
resource "azurerm_network_security_group" "untrust" {
  name                = "nsg-untrust"
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

# Trust NSG - allow all (PAN-OS enforces security policy)
resource "azurerm_network_security_group" "trust" {
  name                = "nsg-trust"
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

# HA NSG - allow HA2 data sync between firewall peers
resource "azurerm_network_security_group" "ha" {
  name                = "nsg-ha"
  location            = var.location
  resource_group_name = var.hub_resource_group_name
  tags                = var.tags

  security_rule {
    name                       = "Allow-HA-Inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = local.ha_subnet_cidr
    destination_address_prefix = local.ha_subnet_cidr
  }

  security_rule {
    name                       = "Allow-HA-Outbound"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = local.ha_subnet_cidr
    destination_address_prefix = local.ha_subnet_cidr
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
# NSG → Subnet Associations
###############################################################################

resource "azurerm_subnet_network_security_group_association" "mgmt" {
  subnet_id                 = azurerm_subnet.mgmt.id
  network_security_group_id = azurerm_network_security_group.mgmt.id
}

resource "azurerm_subnet_network_security_group_association" "untrust" {
  subnet_id                 = azurerm_subnet.untrust.id
  network_security_group_id = azurerm_network_security_group.untrust.id
}

resource "azurerm_subnet_network_security_group_association" "trust" {
  subnet_id                 = azurerm_subnet.trust.id
  network_security_group_id = azurerm_network_security_group.trust.id
}

resource "azurerm_subnet_network_security_group_association" "ha" {
  subnet_id                 = azurerm_subnet.ha.id
  network_security_group_id = azurerm_network_security_group.ha.id
}

###############################################################################
# Public IP Addresses
###############################################################################

# External Load Balancer Public IP (inbound traffic – aplikacja przez AFD)
resource "azurerm_public_ip" "external_lb" {
  name                = "pip-external-lb"
  location            = var.location
  resource_group_name = var.hub_resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  tags                = var.tags
}

# UWAGA: Brak publicznych IP dla Panoramy i firewalli!
# Zarządzanie odbywa się WYŁĄCZNIE przez Hub Azure Bastion (poniżej).
# FW → Panorama komunikacja: prywatne IP (10.0.0.4 → 10.0.0.10)

###############################################################################
# NAT Gateway dla snet-mgmt
# Zapewnia wychodzący dostęp do Internetu dla Panoramy i FW (eth0) bez PIP:
#   - Aktywacja licencji Panoramy (updates.paloaltonetworks.com)
#   - Pobieranie aktualizacji content/app przez management interface FW
###############################################################################

resource "azurerm_public_ip" "nat_gateway_mgmt" {
  name                = "pip-nat-gateway-mgmt"
  location            = var.location
  resource_group_name = var.hub_resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1"]
  tags                = var.tags
}

resource "azurerm_nat_gateway" "mgmt" {
  name                    = "natgw-mgmt"
  location                = var.location
  resource_group_name     = var.hub_resource_group_name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10
  tags                    = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "mgmt" {
  nat_gateway_id       = azurerm_nat_gateway.mgmt.id
  public_ip_address_id = azurerm_public_ip.nat_gateway_mgmt.id
}

resource "azurerm_subnet_nat_gateway_association" "mgmt" {
  subnet_id      = azurerm_subnet.mgmt.id
  nat_gateway_id = azurerm_nat_gateway.mgmt.id
}

###############################################################################
# Hub AzureBastionSubnet + Hub Azure Bastion (Standard SKU)
# Jedyna "brama" do zarządzania Panoramą i firewallami
#
# Dostęp SSH do FW/Panoramy:
#   az network bastion ssh --name bastion-hub --resource-group rg-transit-hub \
#     --target-ip-address 10.0.0.4 --auth-type password --username panadmin
#
# Tunel HTTPS do GUI Panoramy/FW (port forwarding na localhost):
#   az network bastion tunnel --name bastion-hub --resource-group rg-transit-hub \
#     --target-ip-address 10.0.0.10 --resource-port 443 --port 44300
#   # Potem otwórz: https://localhost:44300 (Panorama GUI)
###############################################################################

# AzureBastionSubnet w Hub VNet (10.0.4.0/26)
resource "azurerm_subnet" "hub_bastion" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = var.hub_resource_group_name
  virtual_network_name = azurerm_virtual_network.transit.name
  address_prefixes     = [local.hub_bastion_subnet_cidr] # 10.0.4.0/26
}

# NSG dla Hub Bastion (wymagane przez Azure Bastion)
resource "azurerm_network_security_group" "hub_bastion" {
  name                = "nsg-hub-bastion"
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
  # Azure wymaga portu 3389 (RDP) w tej regule – bez niego NSG nie spełnia compliance check
  # dla AzureBastionSubnet i Azure odrzuca association.
  # Port 443 jest niezbędny dla az network bastion tunnel → PAN-OS HTTPS GUI.
  security_rule {
    name                       = "Allow-SSH-RDP-HTTPS-Outbound"
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
    name                       = "Allow-BastionCommunication-Outbound"
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

resource "azurerm_subnet_network_security_group_association" "hub_bastion" {
  subnet_id                 = azurerm_subnet.hub_bastion.id
  network_security_group_id = azurerm_network_security_group.hub_bastion.id
}

# Public IP dla Hub Bastion
resource "azurerm_public_ip" "bastion_hub" {
  name                = "pip-bastion-hub"
  location            = var.location
  resource_group_name = var.hub_resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

# Hub Azure Bastion Host – Standard SKU z tunelowaniem
resource "azurerm_bastion_host" "hub" {
  name                = "bastion-hub"
  location            = var.location
  resource_group_name = var.hub_resource_group_name
  sku                 = "Standard"

  # tunneling_enabled    – umożliwia az network bastion tunnel (port forwarding)
  # ip_connect_enabled   – umożliwia --target-ip-address zamiast --target-resource-id
  #                        Bez tego flagi az bastion tunnel zwraca:
  #                        "flag cannot be used when IpConnect is not enabled"
  tunneling_enabled      = true
  ip_connect_enabled     = true
  copy_paste_enabled     = true
  file_copy_enabled      = false
  shareable_link_enabled = false
  tags                   = var.tags

  ip_configuration {
    name                 = "ipconfig-bastion-hub"
    subnet_id            = azurerm_subnet.hub_bastion.id
    public_ip_address_id = azurerm_public_ip.bastion_hub.id
  }
}

###############################################################################
# Spoke 1 VNet & Subnets
###############################################################################

resource "azurerm_virtual_network" "spoke1" {
  provider            = azurerm.spoke1
  name                = "vnet-spoke1-app"
  location            = var.location
  resource_group_name = var.spoke1_resource_group_name
  address_space       = [var.spoke1_vnet_address_space]
  tags                = var.tags
}

resource "azurerm_subnet" "spoke1_workload" {
  provider             = azurerm.spoke1
  name                 = "snet-workload"
  resource_group_name  = var.spoke1_resource_group_name
  virtual_network_name = azurerm_virtual_network.spoke1.name
  address_prefixes     = [local.spoke1_workload_cidr]
}

###############################################################################
# Spoke 2 VNet & Subnets
###############################################################################

resource "azurerm_virtual_network" "spoke2" {
  provider            = azurerm.spoke2
  name                = "vnet-spoke2-app"
  location            = var.location
  resource_group_name = var.spoke2_resource_group_name
  address_space       = [var.spoke2_vnet_address_space]
  tags                = var.tags
}

resource "azurerm_subnet" "spoke2_workload" {
  provider             = azurerm.spoke2
  name                 = "snet-workload"
  resource_group_name  = var.spoke2_resource_group_name
  virtual_network_name = azurerm_virtual_network.spoke2.name
  address_prefixes     = [local.spoke2_workload_cidr]
}

###############################################################################
# VNet Peering - Hub ↔ Spoke 1
# Both sides must be created for cross-subscription peering to work
###############################################################################

resource "azurerm_virtual_network_peering" "hub_to_spoke1" {
  name                         = "peer-hub-to-spoke1"
  resource_group_name          = var.hub_resource_group_name
  virtual_network_name         = azurerm_virtual_network.transit.name
  remote_virtual_network_id    = azurerm_virtual_network.spoke1.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true # Required: FW will forward traffic from spoke
  allow_gateway_transit        = false
  use_remote_gateways          = false
}

resource "azurerm_virtual_network_peering" "spoke1_to_hub" {
  provider                     = azurerm.spoke1
  name                         = "peer-spoke1-to-hub"
  resource_group_name          = var.spoke1_resource_group_name
  virtual_network_name         = azurerm_virtual_network.spoke1.name
  remote_virtual_network_id    = azurerm_virtual_network.transit.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false
}

###############################################################################
# VNet Peering - Hub ↔ Spoke 2
###############################################################################

resource "azurerm_virtual_network_peering" "hub_to_spoke2" {
  name                         = "peer-hub-to-spoke2"
  resource_group_name          = var.hub_resource_group_name
  virtual_network_name         = azurerm_virtual_network.transit.name
  remote_virtual_network_id    = azurerm_virtual_network.spoke2.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false
}

resource "azurerm_virtual_network_peering" "spoke2_to_hub" {
  provider                     = azurerm.spoke2
  name                         = "peer-spoke2-to-hub"
  resource_group_name          = var.spoke2_resource_group_name
  virtual_network_name         = azurerm_virtual_network.spoke2.name
  remote_virtual_network_id    = azurerm_virtual_network.transit.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false
}

###############################################################################
# Spoke 1 Workload NSG
# Allows HTTP/HTTPS from Trust subnet (VM-Series) and management SSH
###############################################################################
resource "azurerm_network_security_group" "spoke1_workload" {
  provider            = azurerm.spoke1
  name                = "nsg-spoke1-workload"
  location            = var.location
  resource_group_name = var.spoke1_resource_group_name
  tags                = var.tags

  security_rule {
    name                       = "Allow-HTTP-From-Trust"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = local.trust_subnet_cidr
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
    source_address_prefix      = local.trust_subnet_cidr
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-SSH-From-Mgmt"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = local.mgmt_subnet_cidr
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

resource "azurerm_subnet_network_security_group_association" "spoke1_workload" {
  provider                  = azurerm.spoke1
  subnet_id                 = azurerm_subnet.spoke1_workload.id
  network_security_group_id = azurerm_network_security_group.spoke1_workload.id
}

###############################################################################
# Spoke 2 - AzureBastionSubnet
# Required name is exactly "AzureBastionSubnet", min /26
###############################################################################
resource "azurerm_subnet" "spoke2_bastion" {
  provider             = azurerm.spoke2
  name                 = "AzureBastionSubnet"
  resource_group_name  = var.spoke2_resource_group_name
  virtual_network_name = azurerm_virtual_network.spoke2.name
  address_prefixes     = [cidrsubnet(var.spoke2_vnet_address_space, 10, 1023)] # 10.2.255.192/26
}

###############################################################################
# Spoke 2 Bastion NSG (Azure Bastion requires specific rules)
###############################################################################
resource "azurerm_network_security_group" "spoke2_bastion" {
  provider            = azurerm.spoke2
  name                = "nsg-spoke2-bastion"
  location            = var.location
  resource_group_name = var.spoke2_resource_group_name
  tags                = var.tags

  # Inbound: HTTPS from internet (user browsers)
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

  # Inbound: Azure control plane from GatewayManager
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

  # Inbound: Azure Load Balancer health probe
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

  # Inbound: Bastion host communication
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

  # Outbound: RDP/SSH to VMs
  security_rule {
    name                       = "Allow-RDP-SSH-Outbound"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_ranges    = ["22", "3389"]
    source_address_prefix      = "*"
    destination_address_prefix = "VirtualNetwork"
  }

  # Outbound: Azure Cloud (telemetry)
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

  # Outbound: Bastion host communication
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

  # Outbound: Session info to internet (needed for Bastion)
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

resource "azurerm_subnet_network_security_group_association" "spoke2_bastion" {
  provider                  = azurerm.spoke2
  subnet_id                 = azurerm_subnet.spoke2_bastion.id
  network_security_group_id = azurerm_network_security_group.spoke2_bastion.id
}

###############################################################################
# Spoke 2 Workload NSG
# DC: allow RDP only from AzureBastionSubnet, deny all other inbound
###############################################################################
resource "azurerm_network_security_group" "spoke2_workload" {
  provider            = azurerm.spoke2
  name                = "nsg-spoke2-workload"
  location            = var.location
  resource_group_name = var.spoke2_resource_group_name
  tags                = var.tags

  security_rule {
    name                       = "Allow-RDP-From-Bastion"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3389"
    source_address_prefix      = azurerm_subnet.spoke2_bastion.address_prefixes[0]
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
    source_address_prefix      = local.trust_subnet_cidr
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-Domain-From-Spoke1"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = var.spoke1_vnet_address_space
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

resource "azurerm_subnet_network_security_group_association" "spoke2_workload" {
  provider                  = azurerm.spoke2
  subnet_id                 = azurerm_subnet.spoke2_workload.id
  network_security_group_id = azurerm_network_security_group.spoke2_workload.id
}
