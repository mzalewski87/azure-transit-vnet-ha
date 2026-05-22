###############################################################################
# AKS Cluster Module – Outputs
###############################################################################

output "cluster_id" {
  description = "AKS cluster resource ID"
  value       = azurerm_kubernetes_cluster.aks.id
}

output "cluster_name" {
  description = "AKS cluster name"
  value       = azurerm_kubernetes_cluster.aks.name
}

output "cluster_fqdn" {
  description = "AKS API server FQDN (matches *.hcp.<region>.azmk8s.io wildcard in EDL)"
  value       = azurerm_kubernetes_cluster.aks.fqdn
}

output "kube_config_raw" {
  description = "Raw kubeconfig YAML for kubectl access (sensitive)"
  value       = azurerm_kubernetes_cluster.aks.kube_config_raw
  sensitive   = true
}

# Discrete kubeconfig fields — preferred over kube_config_raw for the
# kubernetes + helm provider configs (lets terraform handle credentials
# without writing a temp file).
output "kube_config_host" {
  description = "AKS API server host (for kubernetes provider)"
  value       = azurerm_kubernetes_cluster.aks.kube_config[0].host
  sensitive   = true
}

output "kube_config_client_certificate" {
  value     = azurerm_kubernetes_cluster.aks.kube_config[0].client_certificate
  sensitive = true
}

output "kube_config_client_key" {
  value     = azurerm_kubernetes_cluster.aks.kube_config[0].client_key
  sensitive = true
}

output "kube_config_cluster_ca_certificate" {
  value     = azurerm_kubernetes_cluster.aks.kube_config[0].cluster_ca_certificate
  sensitive = true
}

output "node_resource_group" {
  description = "Auto-generated MC_* resource group where AKS puts node-pool VMs / disks / LBs"
  value       = azurerm_kubernetes_cluster.aks.node_resource_group
}
