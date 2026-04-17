###############################################################################
# Root Module – Phase 1 (Infrastructure only)
# Azure Transit VNet - Palo Alto VM-Series Active/Passive HA
# Reference: PAN Azure Transit VNet Deployment Guide
#
# DEPLOY IN TWO PHASES:
#
# Phase 1 – Infrastructure (ten katalog):
#   terraform apply \
#     -target=module.networking \
#     -target=module.bootstrap \
#     -target=module.panorama \
#     -target=module.loadbalancer \
#     -target=module.firewall \
#     -target=module.routing \
#     -target=module.frontdoor \
#     -target=module.spoke1_app \
#     -target=module.spoke2_dc
#
# Phase 2 – Konfiguracja Panoramy (osobny katalog):
#   cd phase2-panorama-config/
#   terraform init
#   terraform apply
#   Szczegóły: patrz README.md sekcja "Phase 2"
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
#          User Assigned Managed Identity for secure FW storage access
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

  # Azure Policy compliance: network_rules default_action=Deny
  # mgmt subnet has Microsoft.Storage service endpoint (set in networking module)
  allowed_subnet_ids = [
    module.networking.mgmt_subnet_id,
  ]
  # Public IP(s) of the Terraform operator machine (for blob upload)
  # Get your IP: curl -s https://api.ipify.org
  terraform_operator_ips = var.terraform_operator_ips

  tags = var.tags

  depends_on = [module.networking]
}

#------------------------------------------------------------------------------
# Panorama Module
# Creates: Panorama VM in snet-mgmt (10.0.0.10), public IP, 2TB data disk
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
# Creates: External Standard LB (public) + Internal Standard LB (10.0.2.100)
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
# Creates: 2x VM-Series PAN-OS 11.1 (Active/Passive), 4x NICs per VM,
#          Availability Set, bootstrap via Managed Identity + custom_data
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

  external_lb_backend_pool_id = module.loadbalancer.external_lb_backend_pool_id
  internal_lb_backend_pool_id = module.loadbalancer.internal_lb_backend_pool_id

  bootstrap_custom_data_fw1 = module.bootstrap.fw1_custom_data
  bootstrap_custom_data_fw2 = module.bootstrap.fw2_custom_data
  fw_managed_identity_id    = module.bootstrap.managed_identity_id

  tags = var.tags

  depends_on = [module.bootstrap]
}

#------------------------------------------------------------------------------
# Routing Module
# Creates: UDR Route Tables dla Spoke1 i Spoke2
#          (domyślna trasa + east-west → Internal LB 10.0.2.100)
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
# Creates: Azure Front Door Premium, Endpoint, Origin Group, Route
#          Origin: External LB public IP → VM-Series (DNAT do Apache)
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
# Creates: Ubuntu 22.04 + Apache2 Hello World (cloud-init), IP 10.1.0.4
#          Ruch: AFD → External LB → VM-Series DNAT → ten serwer
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
# Creates: Windows Server 2022 DC (panw.labs, 10.2.0.4)
#          + Azure Bastion Standard (bezpieczny RDP bez publicznego IP na DC)
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

  admin_username    = var.dc_admin_username
  admin_password    = var.dc_admin_password
  domain_name       = var.dc_domain_name
  dc_vm_size        = var.dc_vm_size
  skip_auto_promote = var.dc_skip_auto_promote

  tags = var.tags

  depends_on = [module.routing]
}
