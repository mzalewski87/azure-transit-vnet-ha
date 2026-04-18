###############################################################################
# Root Module – Azure Transit VNet (Infrastructure)
# Palo Alto VM-Series Active/Passive HA Reference Architecture
#
# WYMAGANA KOLEJNOŚĆ DEPLOY (patrz README.md):
#
# ──────────────────────────────────────────────────────────────────────────
# PHASE 1a – Sieć + Panorama + DC/Bastion (BEZ firewalli):
#   terraform apply \
#     -target=azurerm_resource_group.hub \
#     -target=azurerm_resource_group.spoke1 \
#     -target=azurerm_resource_group.spoke2 \
#     -target=module.networking \
#     -target=module.panorama \
#     -target=module.spoke2_dc
#   → Poczekaj na Panoramę, aktywuj licencję przez GUI
#
# PHASE 2 – Konfiguracja Panoramy przez panos provider (PRZED FW!):
#   cd phase2-panorama-config/
#   # Uruchom Bastion tunnel w osobnym terminalu (patrz README.md)
#   terraform init && terraform apply
#   → Tworzy Device Group i Template Stack w Panoramie
#
# PHASE 1b – Bootstrap + Firewalle + reszta infrastruktury:
#   # 1. Wygeneruj Device Registration Auth Key w Panoramie
#   # 2. Ustaw panorama_vm_auth_key w terraform.tfvars
#   terraform apply -target=module.bootstrap
#   terraform apply \
#     -target=module.loadbalancer \
#     -target=module.firewall \
#     -target=module.routing \
#     -target=module.frontdoor \
#     -target=module.spoke1_app
#
# DLACZEGO Phase 2 PRZED Phase 1b:
#   FW bootstrap init-cfg zawiera: tplname=Transit-VNet-Stack, dgname=Transit-VNet-DG
#   Gdy FW startuje, szuka tych obiektów w Panoramie.
#   Phase 2 tworzy je. Bez Phase 2 FW nie może się zarejestrować w Panoramie.
# ──────────────────────────────────────────────────────────────────────────
#
# UWAGA o adresach IP:
#   module.bootstrap.panorama_private_ip = "10.0.0.10"
#     → TO jest IP które FW używa do połączenia z Panoramą (w init-cfg)
#     → FW łączy się bezpośrednio po sieci prywatnej (snet-mgmt)
#   phase2-panorama-config/terraform.tfvars: panorama_hostname = "127.0.0.1"
#     → TO jest IP dla TYLKO panos Terraform provider (przez Bastion tunnel)
#     → NIE wpływa na konfigurację FW
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

  # WAŻNE: To IP (10.0.0.10) trafia do init-cfg.txt jako panorama-server.
  # FW używa tego IP do połączenia z Panoramą przez sieć prywatną snet-mgmt.
  # NIE mylić z panorama_hostname="127.0.0.1" w phase2-panorama-config
  # (to jest tylko dla panos Terraform provider przez Bastion tunnel).
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

  vm_size                = var.panorama_vm_size
  admin_username         = var.admin_username
  admin_password         = var.admin_password
  panorama_serial_number = var.panorama_serial_number
  panorama_auth_code     = var.panorama_auth_code
  log_disk_size_gb       = var.panorama_log_disk_size_gb

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
