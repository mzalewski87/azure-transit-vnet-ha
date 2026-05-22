###############################################################################
# optional/aks-deploy/ — Root Orchestration
#
# Single `terraform apply` deploys 6 phases in dependency order. Multi-step
# -target is NOT needed; depends_on between the modules + null_resource gates
# enforces the correct sequence.
#
# Apply order (~25-35 min total):
#   A. EDL server                  (~ 3-5 min)
#   B. Spoke3 network              (~ 1-2 min)
#   C. Panorama rules + commit-all (~ 3-5 min)
#   D. AKS cluster                 (~10-15 min)
#   E. WordPress + ingress-nginx   (~ 5-7 min)
#   F. AFD endpoint + LB rule 8080 (~ 1-2 min)
#   G. Smoke tests                 (~ 2-5 min)
#
# Prerequisites (must be done in the root module BEFORE running this):
#   - Phase 1a + 1b complete (networking, FWs, ext LB, AFD profile, etc.)
#   - Phase 2a + 2b complete (Panorama Template + DG + base rules pushed to FWs)
#   - Bastion tunnel to Panorama up on 127.0.0.1:44300 (see providers.tf)
#
# Destroy order (reverse — terraform handles automatically):
#   verify → AFD/LB rule → WordPress → AKS → Panorama rules → spoke3 → EDL
###############################################################################

###############################################################################
# Phase A — EDL server
###############################################################################

module "edl_server" {
  source = "./modules/edl_server"

  location             = var.location
  resource_group_name  = var.management_resource_group_name
  management_vnet_name = var.management_vnet_name

  edl_subnet_cidr     = var.edl_subnet_cidr
  edl_private_ip      = var.edl_private_ip
  fw_mgmt_subnet_cidr = var.fw_mgmt_subnet_cidr
  aks_region          = var.aks_region

  admin_username = var.edl_admin_username
  admin_password = var.edl_admin_password
  vm_size        = var.edl_vm_size

  tags = var.tags
}

# Give the EDL VM cloud-init enough time to install nginx + python3 and run
# the generator once. We can't poll the EDL server directly from the machine
# running terraform because the EDL IP (10.255.2.x) sits inside the Azure
# private network — there's no path from a local laptop without a Bastion
# tunnel just for this check, and that's more plumbing than the value it
# adds. Instead, sleep 5 min after VM creation and rely on PAN-OS's own
# EDL retry (5-min default) to converge once the file IS being served.
# Worst case: first EDL pull returns 503, PAN-OS retries 5 min later, list
# populates. Cluster creation has its own ~10-15 min boot window anyway.
resource "time_sleep" "wait_for_edl_bootstrap" {
  depends_on      = [module.edl_server]
  create_duration = "300s"
}

###############################################################################
# Phase B — Spoke3 network
###############################################################################

# Look up the existing transit VNet so we can peer to it without hard-coding
# its resource ID.
data "azurerm_virtual_network" "transit" {
  name                = var.transit_vnet_name
  resource_group_name = var.transit_resource_group_name
}

module "aks_network" {
  source = "./modules/aks_network"

  location                = var.location
  aks_resource_group_name = var.aks_resource_group_name

  spoke3_vnet_address_space = var.spoke3_vnet_address_space
  aks_nodes_subnet_cidr     = var.aks_nodes_subnet_cidr
  aks_ilb_subnet_cidr       = var.aks_ilb_subnet_cidr

  transit_vnet_id             = data.azurerm_virtual_network.transit.id
  transit_vnet_name           = var.transit_vnet_name
  transit_resource_group_name = var.transit_resource_group_name
  internal_lb_private_ip      = var.internal_lb_private_ip

  tags = var.tags

  depends_on = [time_sleep.wait_for_edl_bootstrap]
}

###############################################################################
# Phase C — Panorama rules + commit-all to FWs
###############################################################################

module "panorama_aks_rules" {
  source = "./modules/panorama_aks_rules"

  panorama_hostname = var.panorama_hostname
  panorama_port     = var.panorama_port
  panorama_username = var.panorama_username
  panorama_password = var.panorama_password

  device_group_name = var.panorama_device_group
  template_name     = var.panorama_template

  edl_server_ip         = module.edl_server.private_ip
  aks_spoke_cidr        = module.aks_network.aks_spoke_cidr
  aks_ingress_ip        = var.aks_ingress_internal_lb_ip
  external_lb_public_ip = var.external_lb_public_ip

  tags = var.tags

  depends_on = [
    module.aks_network,
    time_sleep.wait_for_edl_bootstrap,
  ]
}

###############################################################################
# Phase D — AKS cluster (only after FW rules are pushed)
###############################################################################

module "aks_cluster" {
  source = "./modules/aks_cluster"

  location            = var.location
  resource_group_name = module.aks_network.resource_group_name
  aks_nodes_subnet_id = module.aks_network.aks_nodes_subnet_id

  cluster_name       = var.aks_cluster_name
  kubernetes_version = var.aks_kubernetes_version
  node_count         = var.aks_node_count
  node_vm_size       = var.aks_node_vm_size

  tags = var.tags

  # CRITICAL: this depends_on is what makes the entire EDL-before-AKS design
  # work. AKS cluster creation MUST NOT start until commit-all has finished
  # pushing the new security rules + EDL objects to the FWs — otherwise the
  # cluster's first reach-out (kubelet pulling MCR images) is denied by
  # Deny-All and the API server provisioning stalls indefinitely.
  depends_on = [module.panorama_aks_rules]
}

###############################################################################
# Phase E — WordPress (Helm) inside the AKS cluster
###############################################################################

module "wordpress" {
  source = "./modules/wordpress"

  ingress_internal_lb_ip = var.aks_ingress_internal_lb_ip
  ingress_subnet_name    = "snet-aks-ilb"

  wp_admin_username = var.wp_admin_username
  wp_admin_password = var.wp_admin_password
  wp_blog_name      = var.wp_blog_name

  depends_on = [module.aks_cluster]
}

###############################################################################
# Phase F — AFD endpoint + new External LB rule for port 8080
###############################################################################

module "frontdoor_wordpress" {
  source = "./modules/frontdoor_wordpress"

  frontdoor_profile_name        = var.frontdoor_profile_name
  frontdoor_resource_group_name = var.transit_resource_group_name

  external_lb_name                = var.external_lb_name
  external_lb_resource_group_name = var.transit_resource_group_name
  external_lb_public_ip           = var.external_lb_public_ip

  tags = var.tags

  # Ingress LB inside AKS must exist + be responding before AFD origin probes
  # try to reach it via the FW. wordpress module wait=true ensures the chart
  # is settled by the time it returns.
  depends_on = [module.wordpress]
}

###############################################################################
# Phase G — Smoke tests
###############################################################################

resource "null_resource" "smoke_tests" {
  triggers = {
    # Re-run when any of the deployment components change.
    wp_url          = module.frontdoor_wordpress.wordpress_url
    cluster_id      = module.aks_cluster.cluster_id
    edl_ip          = module.edl_server.private_ip
    ingress_lb_rule = module.frontdoor_wordpress.external_lb_rule_name
  }

  provisioner "local-exec" {
    command     = "${path.module}/scripts/verify_deployment.sh"
    interpreter = ["/usr/bin/env", "bash"]

    environment = {
      CLUSTER_NAME  = module.aks_cluster.cluster_name
      CLUSTER_RG    = module.aks_network.resource_group_name
      EDL_IP        = module.edl_server.private_ip
      WORDPRESS_URL = module.frontdoor_wordpress.wordpress_url
    }
  }

  depends_on = [
    module.frontdoor_wordpress,
    module.wordpress,
    module.aks_cluster,
    module.panorama_aks_rules,
  ]
}
