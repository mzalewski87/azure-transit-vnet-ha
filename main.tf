###############################################################################
# Root Module
# Azure Transit VNet - Palo Alto VM-Series Active/Passive HA
# Reference: PAN Azure Transit VNet Deployment Guide
#
# DEPLOY IN TWO PHASES:
#
# Phase 1 – Infrastructure (run first):
#   terraform apply \
#     -target=module.networking \
#     -target=module.loadbalancer \
#     -target=module.bootstrap \
#     -target=module.panorama \
#     -target=module.firewall \
#     -target=module.routing \
#     -target=module.frontdoor \
#     -target=module.spoke1_app \
#     -target=module.spoke2_dc
#
# Phase 2 – Panorama configuration (after ~10 min Panorama boot):
#   1. Get Panorama IP: terraform output panorama_public_ip
#   2. Generate VM Auth Key in Panorama GUI
#   3. Add to terraform.tfvars:
#        panorama_public_ip  = "<panorama_ip>"
#        panorama_vm_auth_key = "<vm_auth_key>"
#   4. terraform apply   # completes module.panorama_config
###############################################################################

#------------------------------------------------------------------------------
# Resource Groups
#------------------------------------------------------------------------------
resource "azurerm_resource_group" "hub" {
  name     = var.hub_resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_resource_group" "spoke1" {
  provider = azurerm.spoke1
  name     = var.spoke1_resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_resource_group" "spoke2" {
  provider = azurerm.spoke2
  name     = var.spoke2_resource_group_name
  location = var.location
  tags     = var.tags
}

#------------------------------------------------------------------------------
# Networking Module
# Creates: Transit VNet, Spoke VNets, Subnets, NSGs, VNet Peerings, Public IPs
#          Spoke workload NSGs, AzureBastionSubnet in Spoke2
#------------------------------------------------------------------------------
module "networking" {
  source = "./modules/networking"

  providers = {
    azurerm        = azurerm
    azurerm.spoke1 = azurerm.spoke1
    azurerm.spoke2 = azurerm.spoke2
  }

  location                   = var.location
  hub_resource_group_name    = azurerm_resource_group.hub.name
  spoke1_resource_group_name = azurerm_resource_group.spoke1.name
  spoke2_resource_group_name = azurerm_resource_group.spoke2.name

  transit_vnet_address_space = var.transit_vnet_address_space
  spoke1_vnet_address_space  = var.spoke1_vnet_address_space
  spoke2_vnet_address_space  = var.spoke2_vnet_address_space

  hub_subscription_id    = var.hub_subscription_id
  spoke1_subscription_id = var.spoke1_subscription_id
  spoke2_subscription_id = var.spoke2_subscription_id

  tags = var.tags
}

#------------------------------------------------------------------------------
# Bootstrap Module
# Creates: Storage Account, bootstrap blobs (init-cfg.txt, authcodes),
#          User Assigned Managed Identity for secure FW access
#------------------------------------------------------------------------------
module "bootstrap" {
  source = "./modules/bootstrap"

  location            = var.location
  resource_group_name = azurerm_resource_group.hub.name

  panorama_private_ip     = "10.0.0.10"
  panorama_template_stack = var.panorama_template_stack
  panorama_device_group   = var.panorama_device_group
  panorama_vm_auth_key    = var.panorama_vm_auth_key

  fw_auth_code = var.fw_auth_code

  tags = var.tags
}

#------------------------------------------------------------------------------
# Panorama Module
# Creates: Panorama VM in snet-mgmt, public IP, 2TB data disk
#------------------------------------------------------------------------------
module "panorama" {
  source = "./modules/panorama"

  location            = var.location
  resource_group_name = azurerm_resource_group.hub.name

  mgmt_subnet_id      = module.networking.mgmt_subnet_id
  panorama_private_ip = "10.0.0.10"

  vm_size            = var.panorama_vm_size
  admin_username     = var.admin_username
  admin_password     = var.admin_password
  panorama_auth_code = var.panorama_auth_code
  log_disk_size_gb   = var.panorama_log_disk_size_gb

  tags = var.tags
}

#------------------------------------------------------------------------------
# Load Balancer Module
# Creates: External Standard LB (public) + Internal Standard LB (private)
#------------------------------------------------------------------------------
module "loadbalancer" {
  source = "./modules/loadbalancer"

  location                 = var.location
  resource_group_name      = azurerm_resource_group.hub.name
  untrust_subnet_id        = module.networking.untrust_subnet_id
  trust_subnet_id          = module.networking.trust_subnet_id
  external_lb_public_ip_id = module.networking.external_lb_public_ip_id
  internal_lb_private_ip   = var.internal_lb_private_ip

  tags = var.tags
}

#------------------------------------------------------------------------------
# Firewall Module
# Creates: 2x VM-Series (Active/Passive), 4x NICs per VM, Availability Set
#          Bootstrap via Managed Identity + custom_data
#------------------------------------------------------------------------------
module "firewall" {
  source = "./modules/firewall"

  location            = var.location
  resource_group_name = azurerm_resource_group.hub.name

  vm_size        = var.fw_vm_size
  admin_username = var.admin_username
  admin_password = var.admin_password
  pan_os_version = var.pan_os_version

  mgmt_subnet_id    = module.networking.mgmt_subnet_id
  untrust_subnet_id = module.networking.untrust_subnet_id
  trust_subnet_id   = module.networking.trust_subnet_id
  ha_subnet_id      = module.networking.ha_subnet_id

  fw1_mgmt_public_ip_id = module.networking.fw1_mgmt_public_ip_id
  fw2_mgmt_public_ip_id = module.networking.fw2_mgmt_public_ip_id

  external_lb_backend_pool_id = module.loadbalancer.external_lb_backend_pool_id
  internal_lb_backend_pool_id = module.loadbalancer.internal_lb_backend_pool_id

  # Bootstrap via Azure Storage Account (Managed Identity)
  bootstrap_custom_data_fw1 = module.bootstrap.fw1_custom_data
  bootstrap_custom_data_fw2 = module.bootstrap.fw2_custom_data
  fw_managed_identity_id    = module.bootstrap.managed_identity_id

  tags = var.tags

  depends_on = [module.bootstrap]
}

#------------------------------------------------------------------------------
# Routing Module
# Creates: UDR Route Tables for Spoke subnets (default + east-west → Internal LB)
#------------------------------------------------------------------------------
module "routing" {
  source = "./modules/routing"

  providers = {
    azurerm        = azurerm
    azurerm.spoke1 = azurerm.spoke1
    azurerm.spoke2 = azurerm.spoke2
  }

  location                   = var.location
  spoke1_resource_group_name = azurerm_resource_group.spoke1.name
  spoke2_resource_group_name = azurerm_resource_group.spoke2.name

  spoke1_workload_subnet_id = module.networking.spoke1_workload_subnet_id
  spoke2_workload_subnet_id = module.networking.spoke2_workload_subnet_id

  internal_lb_private_ip    = module.loadbalancer.internal_lb_private_ip
  spoke1_vnet_address_space = var.spoke1_vnet_address_space
  spoke2_vnet_address_space = var.spoke2_vnet_address_space

  tags = var.tags
}

#------------------------------------------------------------------------------
# Front Door Module
# Creates: Azure Front Door Premium + Endpoint + Origin Group + Route
#          Origin: External LB public IP → VM-Series (DNAT to Apache)
#------------------------------------------------------------------------------
module "frontdoor" {
  source = "./modules/frontdoor"

  resource_group_name   = azurerm_resource_group.hub.name
  frontdoor_sku         = var.frontdoor_sku
  external_lb_public_ip = module.networking.external_lb_public_ip_address

  tags = var.tags
}

#------------------------------------------------------------------------------
# Spoke1 App Module
# Creates: Ubuntu 22.04 VM with Apache2 Hello World (10.1.0.4, Spoke1)
#          Reached via: AFD → External LB → VM-Series DNAT → this VM
#------------------------------------------------------------------------------
module "spoke1_app" {
  source = "./modules/spoke1_app"

  providers = {
    azurerm.spoke1 = azurerm.spoke1
  }

  location            = var.location
  resource_group_name = azurerm_resource_group.spoke1.name
  subnet_id           = module.networking.spoke1_workload_subnet_id
  admin_username      = var.admin_username
  admin_password      = var.admin_password

  tags = var.tags

  depends_on = [module.routing]
}

#------------------------------------------------------------------------------
# Spoke2 DC Module
# Creates: Windows Server 2022 Domain Controller (panw.labs, 10.2.0.4)
#          + Azure Bastion for secure RDP access (no public IP on DC)
#------------------------------------------------------------------------------
module "spoke2_dc" {
  source = "./modules/spoke2_dc"

  providers = {
    azurerm.spoke2 = azurerm.spoke2
  }

  location            = var.location
  resource_group_name = azurerm_resource_group.spoke2.name

  workload_subnet_id = module.networking.spoke2_workload_subnet_id
  bastion_subnet_id  = module.networking.spoke2_bastion_subnet_id

  admin_username = var.dc_admin_username
  admin_password = var.dc_admin_password
  domain_name    = var.dc_domain_name
  dc_vm_size     = var.dc_vm_size

  tags = var.tags

  depends_on = [module.routing]
}

#------------------------------------------------------------------------------
# Panorama Config Module (Phase 2 only)
# Configures Panorama via panos provider:
#   Template, Template Stack, Device Group, Interfaces, Zones,
#   Virtual Router, Static Routes, NAT rules, Security policies
#
# REQUIRES: panorama_public_ip variable set in terraform.tfvars
# Skip in Phase 1 using: -target flags (exclude this module)
#------------------------------------------------------------------------------
module "panorama_config" {
  source = "./modules/panorama_config"

  # Phase 2 only: panorama_public_ip must be set for this module to work
  count = var.panorama_public_ip != "" ? 1 : 0

  panorama_hostname = module.panorama.panorama_public_ip
  panorama_username = var.admin_username
  panorama_password = var.admin_password

  template_name       = "Transit-VNet-Template"
  template_stack_name = var.panorama_template_stack
  device_group_name   = var.panorama_device_group

  trust_subnet_cidr   = "10.0.2.0/24"
  untrust_subnet_cidr = "10.0.1.0/24"
  spoke1_vnet_cidr    = var.spoke1_vnet_address_space
  spoke2_vnet_cidr    = var.spoke2_vnet_address_space

  apache_server_ip      = module.spoke1_app.apache_private_ip
  external_lb_public_ip = module.networking.external_lb_public_ip_address

  depends_on = [module.panorama, module.spoke1_app]
}
