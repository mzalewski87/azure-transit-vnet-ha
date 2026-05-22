###############################################################################
# AKS Cluster Module
#
# Creates the AKS cluster in spoke3 with:
#   - Azure CNI Overlay network plugin (pods on pod_cidr, NOT VNet IPs)
#   - outbound_type = userDefinedRouting (forces egress through transit FWs
#     via the UDR installed by aks_network module)
#   - User-Assigned Managed Identity (cluster + kubelet identities both)
#   - Network Contributor role on the spoke3 RG so AKS can manage subnets,
#     internal LBs, etc.
#   - 2x Standard_D2s_v3 nodes (modest — enough to schedule WordPress +
#     ingress-nginx + system pods)
#   - Public API server (private would require additional networking work;
#     out of scope for the initial demo)
#
# CRITICAL: This module must depend on panorama_aks_rules — without the FW
# rules pushed to the device group BEFORE cluster creation, AKS API calls
# from kubelet to MCR/Konnectivity will be denied and cluster creation will
# stall in "Creating" for ~15-20 min before failing.
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
# Managed Identity for the AKS cluster
###############################################################################

resource "azurerm_user_assigned_identity" "aks" {
  name                = "uai-${var.cluster_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# AKS needs Network Contributor on the spoke3 RG so it can create internal LBs
# for our ingress-nginx service (LoadBalancer type with internal annotation).
# Without this, the LB creation fails with AuthorizationFailed when the service
# is applied.
data "azurerm_resource_group" "aks" {
  name = var.resource_group_name
}

resource "azurerm_role_assignment" "aks_network_contributor" {
  scope                = data.azurerm_resource_group.aks.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
}

###############################################################################
# AKS cluster
###############################################################################

resource "azurerm_kubernetes_cluster" "aks" {
  name                = var.cluster_name
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = var.cluster_name
  kubernetes_version  = var.kubernetes_version
  tags                = var.tags

  # Public API endpoint — keeps demo simple. Private cluster would require:
  #   - private_cluster_enabled = true
  #   - private_dns_zone_id pointing to a managed/custom DNS zone
  #   - kubectl access from inside the VNet only (Bastion + Linux jumpbox)
  # All achievable later; default disables for simplicity.
  private_cluster_enabled = false

  default_node_pool {
    name                 = "system"
    node_count           = var.node_count
    vm_size              = var.node_vm_size
    vnet_subnet_id       = var.aks_nodes_subnet_id
    orchestrator_version = var.kubernetes_version
    type                 = "VirtualMachineScaleSets"
    os_disk_size_gb      = 64
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks.id]
  }

  # Letting AKS auto-create + manage the kubelet identity (in the MC_* RG)
  # — sidesteps the "Managed Identity Operator" role-assignment requirement
  # we'd otherwise need on a BYO kubelet identity. The cluster identity
  # above (uai-<cluster>) still owns the AKS control-plane operations.

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_policy      = "calico"

    # outbound_type=userDefinedRouting is the lever that makes this entire
    # design work. With this set, AKS does NOT create its own public LB for
    # egress; instead it expects 0.0.0.0/0 to be routed elsewhere — in our
    # case to the transit Internal LB (10.110.0.21) which fronts the FW pair.
    # The UDR was installed by aks_network module.
    outbound_type = "userDefinedRouting"

    load_balancer_sku = "standard"
    pod_cidr          = var.pod_cidr
    service_cidr      = var.service_cidr
    dns_service_ip    = var.dns_service_ip
  }

  # Local accounts kept enabled so the kubernetes + helm providers can use
  # the admin kubeconfig directly. AAD-RBAC (azure_active_directory_role_based_access_control)
  # is intentionally omitted — it requires either tenant_id + admin group
  # bindings or full client_app_id/server_app_id (legacy mode), both of
  # which add input complexity for a demo. Re-enable later by adding a
  # block with `tenant_id = var.aad_tenant_id` once AAD is desired.
  local_account_disabled = false

  depends_on = [azurerm_role_assignment.aks_network_contributor]
}
