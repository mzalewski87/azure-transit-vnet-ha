###############################################################################
# Root Module Outputs
###############################################################################

#--- Network IPs ---
output "external_lb_public_ip" {
  description = "External Load Balancer public IP (inbound via AFD)"
  value       = module.networking.external_lb_public_ip_address
}

output "internal_lb_private_ip" {
  description = "Internal Load Balancer private IP (UDR next-hop)"
  value       = module.loadbalancer.internal_lb_private_ip
}

output "panorama_private_ip" {
  description = "Panorama private IP (Management VNet)"
  value       = var.panorama_private_ip
}

#--- Resource IDs (for Bastion commands) ---
output "panorama_vm_id" {
  description = "Panorama VM resource ID (for Bastion tunnel --target-resource-id)"
  value       = module.panorama.panorama_vm_id
}

output "dc_vm_id" {
  description = "DC VM resource ID"
  value       = module.app2_dc.dc_vm_id
}

#--- Bastion ---
output "bastion_name" {
  description = "Azure Bastion name (Management VNet)"
  value       = module.networking.bastion_name
}

output "bastion_resource_group" {
  description = "Azure Bastion resource group"
  value       = module.networking.bastion_resource_group
}

#--- Bootstrap SA ---
output "bootstrap_storage_account" {
  description = "Bootstrap Storage Account name"
  value       = module.bootstrap.storage_account_name
}

#--- Front Door ---
output "frontdoor_endpoint" {
  description = "Azure Front Door endpoint hostname"
  value       = module.frontdoor.frontdoor_endpoint_hostname
}
