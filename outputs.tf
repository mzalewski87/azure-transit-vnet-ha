###############################################################################
# Root Module Outputs
# Run: terraform output   (after apply)
###############################################################################

#------------------------------------------------------------------------------
# Management Access
#------------------------------------------------------------------------------
output "fw1_management_public_ip" {
  description = "FW1 management public IP – open https://<ip> in browser"
  value       = module.networking.fw1_mgmt_public_ip_address
}

output "fw2_management_public_ip" {
  description = "FW2 management public IP – open https://<ip> in browser"
  value       = module.networking.fw2_mgmt_public_ip_address
}

output "panorama_public_ip" {
  description = "Panorama management public IP – open https://<ip> in browser. Use this value for panorama_public_ip variable in Phase 2"
  value       = module.panorama.panorama_public_ip
}

output "panorama_private_ip" {
  description = "Panorama private IP (used in FW bootstrap init-cfg.txt as panorama-server)"
  value       = module.panorama.panorama_private_ip
}

#------------------------------------------------------------------------------
# Load Balancers
#------------------------------------------------------------------------------
output "external_lb_public_ip" {
  description = "External Load Balancer public IP – inbound traffic entry point"
  value       = module.networking.external_lb_public_ip_address
}

output "internal_lb_private_ip" {
  description = "Internal Load Balancer private IP – UDR next-hop in Spoke VNets"
  value       = module.loadbalancer.internal_lb_private_ip
}

#------------------------------------------------------------------------------
# Azure Front Door
#------------------------------------------------------------------------------
output "frontdoor_endpoint_hostname" {
  description = "Azure Front Door endpoint hostname – use this URL to test Hello World app"
  value       = module.frontdoor.frontdoor_endpoint_hostname
}

#------------------------------------------------------------------------------
# Application Servers
#------------------------------------------------------------------------------
output "apache_server_private_ip" {
  description = "Apache Hello World server private IP in Spoke1 (DNAT target)"
  value       = module.spoke1_app.apache_private_ip
}

output "domain_controller_private_ip" {
  description = "Windows Server DC private IP in Spoke2 (User-ID Agent target)"
  value       = module.spoke2_dc.dc_private_ip
}

output "domain_name" {
  description = "Active Directory domain name"
  value       = var.dc_domain_name
}

#------------------------------------------------------------------------------
# Azure Bastion (Spoke2 DC access)
#------------------------------------------------------------------------------
output "bastion_public_ip" {
  description = "Azure Bastion public IP for Spoke2 – use Azure Portal Bastion to RDP to DC"
  value       = module.spoke2_dc.bastion_public_ip
}

output "bastion_dns_name" {
  description = "Azure Bastion DNS hostname"
  value       = module.spoke2_dc.bastion_dns_name
}

#------------------------------------------------------------------------------
# Bootstrap
#------------------------------------------------------------------------------
output "bootstrap_storage_account" {
  description = "Bootstrap storage account name"
  value       = module.bootstrap.storage_account_name
}

#------------------------------------------------------------------------------
# Routing
#------------------------------------------------------------------------------
output "spoke1_route_table_name" {
  description = "Route table name for Spoke1 workload subnet"
  value       = module.routing.spoke1_route_table_name
}

output "spoke2_route_table_name" {
  description = "Route table name for Spoke2 workload subnet"
  value       = module.routing.spoke2_route_table_name
}
