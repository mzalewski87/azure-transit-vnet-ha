###############################################################################
# optional/aks-deploy/ — Outputs
###############################################################################

output "wordpress_url" {
  description = "Public WordPress URL via Azure Front Door (open this in a browser)"
  value       = module.frontdoor_wordpress.wordpress_url
}

output "wordpress_admin_login" {
  description = "WordPress admin login URL"
  value       = "${module.frontdoor_wordpress.wordpress_url}/wp-login.php"
}

output "wordpress_admin_username" {
  description = "WordPress admin username (password is the wp_admin_password input)"
  value       = var.wp_admin_username
}

output "aks_cluster_name" {
  description = "AKS cluster name (for az aks get-credentials)"
  value       = module.aks_cluster.cluster_name
}

output "aks_resource_group" {
  description = "Resource group containing the AKS cluster"
  value       = module.aks_network.resource_group_name
}

output "aks_get_credentials_command" {
  description = "Ready-to-paste command for kubectl access"
  value       = "az aks get-credentials --name ${module.aks_cluster.cluster_name} --resource-group ${module.aks_network.resource_group_name}"
}

output "edl_server_ip" {
  description = "Private IP of the EDL nginx server"
  value       = module.edl_server.private_ip
}

output "edl_fqdn_list_url" {
  description = "URL the FW pulls for the FQDN allowlist (verify with curl from FW MGMT subnet)"
  value       = module.edl_server.fqdn_edl_url
}

output "edl_ips_list_url" {
  description = "URL the FW pulls for the IP allowlist"
  value       = module.edl_server.ips_edl_url
}

output "panorama_aks_rules_added" {
  description = "Rule names added to the Panorama Device Group"
  value = {
    edl_fqdn         = module.panorama_aks_rules.fqdn_edl_name
    edl_ips          = module.panorama_aks_rules.ips_edl_name
    address_object   = module.panorama_aks_rules.aks_spoke_address_object
    inbound_nat_rule = module.panorama_aks_rules.wordpress_dnat_rule
  }
}
