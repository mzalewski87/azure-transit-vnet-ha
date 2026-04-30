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
# REQUIRED DEPLOYMENT ORDER (5 phases):
#
# ──────────────────────────────────────────────────────────────────────────────
# PHASE 1a – Base infrastructure (no DC, no FW):
#   terraform apply \
#     -target=azurerm_resource_group.hub \
#     -target=azurerm_resource_group.app1 \
#     -target=azurerm_resource_group.app2 \
#     -target=module.networking \
#     -target=module.bootstrap \
#     -target=module.panorama
#
#   → Panorama boots ~10-15 min. No bootstrap — starts with default hostname.
#   → License activation and configuration: Phase 2a (script).
#
# PHASE 2a – Panorama Configuration (automated — single script):
#   bash scripts/configure-panorama.sh
#
#   → Manages Bastion tunnel automatically
#   → Sets: hostname, serial number (license), vm-auth-key,
#     Template Stack, Device Group, interfaces (DHCP), zones, routes, NAT, security
#   → Generates panorama_vm_auth_key.auto.tfvars (auto-loaded in Phase 1b)
#
# PHASE 1b – VM-Series FW + Load Balancer + Routing + Front Door + App1:
#   terraform apply \
#     -target=module.bootstrap \
#     -target=module.loadbalancer \
#     -target=module.firewall \
#     -target=module.routing \
#     -target=module.frontdoor \
#     -target=module.app1_app
#
#   → vm-auth-key auto-loaded from .auto.tfvars (zero manual editing!)
#   → FW boots → activates license with auth code → connects to Panorama
#
# PHASE 2b – FW Registration on Panorama (automated — single script):
#   bash scripts/register-fw-panorama.sh
#
#   → Opens Bastion tunnels to FW1, FW2, Panorama
#   → Reads FW serials (dynamically generated during activation)
#   → Sets auth-key on FW, adds serials to Panorama (mgt-config + DG + TS)
#   → Commit on Panorama → FW connected + in sync
#
# PHASE 3 – DC (optional, independent):
#   terraform apply -target=module.app2_dc
#
# WHY this order:
#   FW init-cfg contains tplname= and dgname= which must exist on Panorama.
#   Phase 2a creates them. FW tries to register at startup.
#   Phase 2b adds dynamic FW serials to Panorama after their activation.
# ──────────────────────────────────────────────────────────────────────────────
###############################################################################

#------------------------------------------------------------------------------
# Locals
# internal_lb_private_ip computed automatically from transit_vnet_address_space
# snet-private = cidrsubnet(transit, 8, 0) → host #21 (e.g. 10.110.0.21)
# Can override internal_lb_private_ip variable if different value needed
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

  location                 = var.location
  hub_resource_group_name  = azurerm_resource_group.hub.name
  app1_resource_group_name = azurerm_resource_group.app1.name
  app2_resource_group_name = azurerm_resource_group.app2.name

  management_vnet_address_space = var.management_vnet_address_space
  transit_vnet_address_space    = var.transit_vnet_address_space
  app1_vnet_address_space       = var.app1_vnet_address_space
  app2_vnet_address_space       = var.app2_vnet_address_space

  hub_subscription_id    = var.hub_subscription_id
  spoke1_subscription_id = var.spoke1_subscription_id
  spoke2_subscription_id = var.spoke2_subscription_id

  tags = var.tags
}

#------------------------------------------------------------------------------
# Bootstrap Module
# Renders FW1+FW2 init-cfg.txt (output as base64 custom_data) +
# User Assigned Managed Identity attached to FW VMs.
# Panorama uses its own (no-op) bootstrap; configured in Phase 2 via XML API.
#------------------------------------------------------------------------------
module "bootstrap" {
  source = "./modules/bootstrap"

  location            = var.location
  resource_group_name = azurerm_resource_group.hub.name

  panorama_private_ip     = var.panorama_private_ip
  panorama_template_stack = var.panorama_template_stack
  panorama_device_group   = var.panorama_device_group
  panorama_vm_auth_key    = var.panorama_vm_auth_key
  fw_auth_code            = var.fw_auth_code

  tags = var.tags
}

#------------------------------------------------------------------------------
# Panorama Module
# Creates: Panorama VM in Management VNet (10.255.0.4), 2TB data disk
# Bootstrap: NONE — Panorama starts without custom_data
#            Hostname, license, Template Stack, Device Group → Phase 2 (XML API)
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

  # Bootstrap renders init-cfg used as custom_data — must exist before FW VMs
  # because customData is immutable after VM creation.
  depends_on = [module.bootstrap]
}

#------------------------------------------------------------------------------
# Routing Module
# Creates: UDR Route Tables for App1 and App2
#          0.0.0.0/0 → Internal LB (10.110.0.21), east-west also through FW
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
# Bastion: In Management VNet (networking module) — not here
#------------------------------------------------------------------------------
module "app2_dc" {
  source = "./modules/spoke2_dc"

  providers = {
    azurerm.spoke2 = azurerm.spoke2
  }

  location            = var.location
  resource_group_name = azurerm_resource_group.app2.name

  workload_subnet_id = module.networking.spoke2_workload_subnet_id
  dc_private_ip      = cidrhost(cidrsubnet(var.app2_vnet_address_space, 8, 0), 4)

  admin_username    = var.dc_admin_username
  admin_password    = var.dc_admin_password
  domain_name       = var.dc_domain_name
  dc_vm_size        = var.dc_vm_size
  skip_auto_promote = var.dc_skip_auto_promote

  tags = var.tags

  depends_on = [module.routing]
}
