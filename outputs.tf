###############################################################################
# Root Module Outputs
# Run: terraform output   (after apply)
###############################################################################

#------------------------------------------------------------------------------
# Hub Azure Bastion – jedyny punkt dostępu do zarządzania FW i Panoramą
#------------------------------------------------------------------------------
output "hub_bastion_name" {
  description = "Hub Bastion name – używany w komendach az network bastion"
  value       = module.networking.hub_bastion_name
}

output "hub_bastion_rg" {
  description = "Resource Group Hub Bastion"
  value       = module.networking.hub_bastion_rg
}

output "hub_bastion_public_ip" {
  description = "Hub Bastion public IP (dostęp przez Azure Portal lub az CLI)"
  value       = module.networking.hub_bastion_public_ip
}

output "nat_gateway_public_ip" {
  description = "NAT Gateway public IP (wychodząca komunikacja z snet-mgmt – licencje, updates)"
  value       = module.networking.nat_gateway_public_ip
}

#------------------------------------------------------------------------------
# Firewall – prywatne IPs (dostęp przez Hub Bastion)
#------------------------------------------------------------------------------
output "fw1_mgmt_private_ip" {
  description = "FW1 management private IP (10.0.0.4) – SSH/GUI przez Hub Bastion"
  value       = module.firewall.fw1_mgmt_private_ip
}

output "fw2_mgmt_private_ip" {
  description = "FW2 management private IP (10.0.0.5) – SSH/GUI przez Hub Bastion"
  value       = module.firewall.fw2_mgmt_private_ip
}

#------------------------------------------------------------------------------
# Panorama – prywatne IP (dostęp przez Hub Bastion)
#------------------------------------------------------------------------------
output "panorama_private_ip" {
  description = "Panorama private IP (10.0.0.10) – dostęp przez Hub Bastion tunnel"
  value       = module.panorama.panorama_private_ip
}

output "panorama_vm_id" {
  description = "Panorama VM resource ID (az network bastion tunnel --target-resource-id)"
  value       = module.panorama.panorama_vm_id
}

#------------------------------------------------------------------------------
# Load Balancers
#------------------------------------------------------------------------------
output "external_lb_public_ip" {
  description = "External Load Balancer public IP – inbound traffic entry point (AFD origin)"
  value       = module.networking.external_lb_public_ip_address
}

output "internal_lb_private_ip" {
  description = "Internal Load Balancer private IP – UDR next-hop w Spoke VNetach"
  value       = module.loadbalancer.internal_lb_private_ip
}

#------------------------------------------------------------------------------
# Azure Front Door
#------------------------------------------------------------------------------
output "frontdoor_endpoint_hostname" {
  description = "Azure Front Door endpoint hostname – URL aplikacji Hello World"
  value       = module.frontdoor.frontdoor_endpoint_hostname
}

#------------------------------------------------------------------------------
# Application Servers
#------------------------------------------------------------------------------
output "apache_server_private_ip" {
  description = "Apache Hello World server private IP w Spoke1 (DNAT target)"
  value       = module.spoke1_app.apache_private_ip
}

output "domain_controller_private_ip" {
  description = "Windows Server DC private IP w Spoke2 (User-ID Agent target)"
  value       = module.spoke2_dc.dc_private_ip
}

output "domain_name" {
  description = "Active Directory domain name"
  value       = var.dc_domain_name
}

#------------------------------------------------------------------------------
# Azure Bastion – Spoke2 DC access
#------------------------------------------------------------------------------
output "spoke2_bastion_public_ip" {
  description = "Spoke2 Bastion public IP – RDP do DC przez Azure Portal"
  value       = module.spoke2_dc.bastion_public_ip
}

output "spoke2_bastion_dns_name" {
  description = "Spoke2 Bastion DNS hostname"
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
