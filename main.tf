###############################################################################
# Root Module – Azure Transit VNet HA Reference Architecture
# Palo Alto VM-Series Active/Passive HA (per PANW Azure Transit VNet Guide)
#
# VNet Topology:
#   Management VNet (10.255.0.0/16)  – Panorama + Azure Bastion Standard
#   Transit Hub VNet (10.110.0.0/16) – VM-Series FW1 (Active) + FW2 (Passive)
#   App1 VNet (10.112.0.0/16)        – Application workloads (Apache Hello World)
#   App2 VNet (10.113.0.0/16)        – Windows Server 2022 DC
#
# WYMAGANA KOLEJNOŚĆ WDROŻENIA:
#
# ──────────────────────────────────────────────────────────────────────────────
# PHASE 1a – Infrastruktura bazowa (Management + Transit + Apps):
#   terraform apply \
#     -target=azurerm_resource_group.hub \
#     -target=azurerm_resource_group.app1 \
#     -target=azurerm_resource_group.app2 \
#     -target=module.networking \
#     -target=module.bootstrap \
#     -target=module.panorama \
#     -target=module.app2_dc
#
#   → Panorama bootuje ~10-15 min. Brak bootstrap – startuje z domyślnym hostname.
#   → Aktywacja licencji i konfiguracja: Phase 2 (XML API).
#
# PHASE 2 – Konfiguracja Panoramy (Template Stack, Device Group, Security/NAT rules):
#   cd phase2-panorama-config/
#   # Terminal 1: Bastion tunnel
#   PANORAMA_ID=$(cd .. && terraform output -raw panorama_vm_id)
#   az network bastion tunnel --name bastion-management \
#     --resource-group rg-transit-hub \
#     --target-resource-id "$PANORAMA_ID" \
#     --resource-port 443 --port 44300
#   # Terminal 2:
#   terraform init && terraform apply
#
# PHASE 1b – VM-Series FW + Load Balancer + Front Door + App:
#   # 1. Wygeneruj vm-auth-key przez SSH do Panoramy:
#   #    az network bastion ssh --name bastion-management \
#   #      --resource-group rg-transit-hub \
#   #      --target-ip-address 10.255.0.4 \
#   #      --auth-type password --username panadmin
#   #    admin@panorama> request authkey add name authkey1 lifetime 60 count 2
#   # 2. Ustaw panorama_vm_auth_key w terraform.tfvars
#   terraform apply -target=module.bootstrap   # aktualizuje FW init-cfg z vm-auth-key
#   terraform apply \
#     -target=module.loadbalancer \
#     -target=module.firewall \
#     -target=module.routing \
#     -target=module.frontdoor \
#     -target=module.app1_app
#
# DLACZEGO ta kolejność:
#   FW init-cfg zawiera tplname= i dgname= które muszą istnieć w Panoramie.
#   Phase 2 tworzy je. FW próbuje zarejestrować się przy starcie.
# ──────────────────────────────────────────────────────────────────────────────
###############################################################################

#------------------------------------------------------------------------------
# Locals
# internal_lb_private_ip obliczany automatycznie z transit_vnet_address_space
# snet-private = cidrsubnet(transit, 8, 0) → host #21 (np. 10.110.0.21)
# Można nadpisać zmienną internal_lb_private_ip jeśli wymagana inna wartość
#------------------------------------------------------------------------------
locals {
  internal_lb_private_ip = var.internal_lb_private_ip != "" ? var.internal_lb_private_ip : cidrhost(cidrsubnet(var.transit_vnet_address_space, 8, 0), 21)
}

#------------------------------------------------------------------------------
# Resource Groups
#------------------------------------------------------------------------------
resource "azurerm_resource_group" "hub" {
  name     = var.hub_resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_resource_group" "app1" {
  provider = azurerm.spoke1
  name     = var.app1_resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_resource_group" "app2" {
  provider = azurerm.spoke2
  name     = var.app2_resource_group_name
  location = var.location
  tags     = var.tags
}

#------------------------------------------------------------------------------
# Networking Module
# Creates: Management VNet (Panorama + Bastion), Transit VNet (FW),
#          App1 + App2 VNets, NSGs, VNet Peerings, NAT Gateways, External LB PIP
#------------------------------------------------------------------------------
module "networking" {
  source = "./modules/networking"

  providers = {
    azurerm        = azurerm
    azurerm.spoke1 = azurerm.spoke1
    azurerm.spoke2 = azurerm.spoke2
  }

  location                       = var.location
  hub_resource_group_name        = azurerm_resource_group.hub.name
  app1_resource_group_name       = azurerm_resource_group.app1.name
  app2_resource_group_name       = azurerm_resource_group.app2.name

  management_vnet_address_space  = var.management_vnet_address_space
  transit_vnet_address_space     = var.transit_vnet_address_space
  app1_vnet_address_space        = var.app1_vnet_address_space
  app2_vnet_address_space        = var.app2_vnet_address_space

  hub_subscription_id            = var.hub_subscription_id
  spoke1_subscription_id         = var.spoke1_subscription_id
  spoke2_subscription_id         = var.spoke2_subscription_id

  tags = var.tags
}

#------------------------------------------------------------------------------
# Bootstrap Module
# Creates: Storage Account, FW1+FW2 bootstrap blobs (init-cfg, authcodes),
#          User Assigned Managed Identity for FW SA access
# SCOPE: WYŁĄCZNIE dla VM-Series FW. Panorama używa bezpośredniej init-cfg w customData.
#------------------------------------------------------------------------------
module "bootstrap" {
  source = "./modules/bootstrap"

  location            = var.location
  resource_group_name = azurerm_resource_group.hub.name

  # Panorama IP w Management VNet – trafia do FW init-cfg jako panorama-server=
  panorama_private_ip     = var.panorama_private_ip
  panorama_template_stack = var.panorama_template_stack
  panorama_device_group   = var.panorama_device_group
  panorama_vm_auth_key    = var.panorama_vm_auth_key
  fw_auth_code            = var.fw_auth_code

  # Azure Policy compliance: SA network_rules.default_action = Deny
  # Transit FW mgmt subnet ma Microsoft.Storage service endpoint
  allowed_subnet_ids = [
    module.networking.mgmt_subnet_id,
  ]

  terraform_operator_ips = var.terraform_operator_ips

  tags = var.tags

  depends_on = [module.networking]
}

#------------------------------------------------------------------------------
# Panorama Module
# Creates: Panorama VM w Management VNet (10.255.0.4), 2TB data disk
# Bootstrap: BRAK – Panorama startuje bez custom_data
#            Hostname, licencja, Template Stack, Device Group → Phase 2 (XML API)
#------------------------------------------------------------------------------
module "panorama" {
  source = "./modules/panorama"

  location            = var.location
  resource_group_name = azurerm_resource_group.hub.name

  # Management VNet subnet (10.255.0.0/24)
  management_subnet_id = module.networking.management_subnet_id
  panorama_private_ip  = var.panorama_private_ip

  vm_size        = var.panorama_vm_size
  admin_username = var.admin_username
  admin_password = var.admin_password

  log_disk_size_gb = var.panorama_log_disk_size_gb

  tags = var.tags
}

#------------------------------------------------------------------------------
# Load Balancer Module
# Creates: External Standard LB (Public IP) + Internal Standard LB (10.110.0.21)
#------------------------------------------------------------------------------
module "loadbalancer" {
  source = "./modules/loadbalancer"

  location                 = var.location
  resource_group_name      = azurerm_resource_group.hub.name
  untrust_subnet_id        = module.networking.untrust_subnet_id
  trust_subnet_id          = module.networking.trust_subnet_id
  external_lb_public_ip_id = module.networking.external_lb_public_ip_id
  internal_lb_private_ip   = local.internal_lb_private_ip

  tags = var.tags
}

#------------------------------------------------------------------------------
# Firewall Module
# Creates: 2x VM-Series PAN-OS (FW1 Active + FW2 Passive), 4x NICs per VM,
#          Availability Set, bootstrap via SA storage pointer
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

  mgmt_subnet_cidr    = module.networking.mgmt_subnet_cidr
  untrust_subnet_cidr = module.networking.untrust_subnet_cidr
  trust_subnet_cidr   = module.networking.trust_subnet_cidr
  ha_subnet_cidr      = module.networking.ha_subnet_cidr

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
# Creates: UDR Route Tables dla App1 i App2
#          0.0.0.0/0 → Internal LB (10.110.0.21), east-west również przez FW
#------------------------------------------------------------------------------
module "routing" {
  source = "./modules/routing"

  providers = {
    azurerm        = azurerm
    azurerm.spoke1 = azurerm.spoke1
    azurerm.spoke2 = azurerm.spoke2
  }

  location                   = var.location
  spoke1_resource_group_name = azurerm_resource_group.app1.name
  spoke2_resource_group_name = azurerm_resource_group.app2.name

  spoke1_workload_subnet_id = module.networking.spoke1_workload_subnet_id
  spoke2_workload_subnet_id = module.networking.spoke2_workload_subnet_id

  internal_lb_private_ip    = module.loadbalancer.internal_lb_private_ip
  spoke1_vnet_address_space = var.app1_vnet_address_space
  spoke2_vnet_address_space = var.app2_vnet_address_space

  tags = var.tags
}

#------------------------------------------------------------------------------
# Front Door Module
# Creates: Azure Front Door Premium, Endpoint, Origin Group → External LB
#------------------------------------------------------------------------------
module "frontdoor" {
  source = "./modules/frontdoor"

  resource_group_name   = azurerm_resource_group.hub.name
  frontdoor_sku         = var.frontdoor_sku
  external_lb_public_ip = module.networking.external_lb_public_ip_address

  tags = var.tags
}

#------------------------------------------------------------------------------
# App1 Application Module
# Creates: Ubuntu 22.04 + Apache2 Hello World (cloud-init), IP 10.112.0.4
#------------------------------------------------------------------------------
module "app1_app" {
  source = "./modules/spoke1_app"

  providers = {
    azurerm.spoke1 = azurerm.spoke1
  }

  location            = var.location
  resource_group_name = azurerm_resource_group.app1.name
  subnet_id           = module.networking.spoke1_workload_subnet_id
  private_ip          = cidrhost(module.networking.app1_workload_subnet_cidr, 4)
  admin_username      = var.admin_username
  admin_password      = var.admin_password

  tags = var.tags

  depends_on = [module.routing]
}

#------------------------------------------------------------------------------
# App2 DC Module
# Creates: Windows Server 2022 DC (panw.labs, 10.113.0.4)
# Bastion: W Management VNet (moduł networking) – nie tutaj
#------------------------------------------------------------------------------
module "app2_dc" {
  source = "./modules/spoke2_dc"

  providers = {
    azurerm.spoke2 = azurerm.spoke2
  }

  location            = var.location
  resource_group_name = azurerm_resource_group.app2.name

  workload_subnet_id = module.networking.spoke2_workload_subnet_id

  admin_username    = var.dc_admin_username
  admin_password    = var.dc_admin_password
  domain_name       = var.dc_domain_name
  dc_vm_size        = var.dc_vm_size
  skip_auto_promote = var.dc_skip_auto_promote

  tags = var.tags

  depends_on = [module.routing]
}
