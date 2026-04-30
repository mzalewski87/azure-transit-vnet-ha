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

#--- Firewall IPs ---
output "fw1_mgmt_private_ip" {
  description = "FW1 management interface IP (snet-mgmt, for Bastion SSH/HTTPS)"
  value       = module.firewall.fw1_mgmt_private_ip
}

output "fw2_mgmt_private_ip" {
  description = "FW2 management interface IP (snet-mgmt, for Bastion SSH/HTTPS)"
  value       = module.firewall.fw2_mgmt_private_ip
}

output "fw1_untrust_private_ip" {
  description = "FW1 untrust interface IP (snet-public, eth1/1)"
  value       = module.firewall.fw1_untrust_private_ip
}

output "fw2_untrust_private_ip" {
  description = "FW2 untrust interface IP (snet-public, eth1/1)"
  value       = module.firewall.fw2_untrust_private_ip
}

output "fw1_trust_private_ip" {
  description = "FW1 trust interface IP (snet-private, eth1/2)"
  value       = module.firewall.fw1_trust_private_ip
}

output "fw2_trust_private_ip" {
  description = "FW2 trust interface IP (snet-private, eth1/2)"
  value       = module.firewall.fw2_trust_private_ip
}

#--- Resource IDs (for Bastion commands) ---
output "panorama_vm_id" {
  description = "Panorama VM resource ID (for Bastion tunnel --target-resource-id)"
  value       = module.panorama.panorama_vm_id
}

output "fw1_vm_id" {
  description = "FW1 VM resource ID (for Bastion tunnel --target-resource-id)"
  value       = module.firewall.fw1_vm_id
}

output "fw2_vm_id" {
  description = "FW2 VM resource ID (for Bastion tunnel --target-resource-id)"
  value       = module.firewall.fw2_vm_id
}

output "dc_vm_id" {
  description = "DC VM resource ID"
  value       = module.app2_dc.dc_vm_id
}

output "apache_vm_id" {
  description = "Apache server (Spoke1) VM resource ID — for Bastion tunnel/SSH"
  value       = module.app1_app.apache_vm_id
}

output "apache_private_ip" {
  description = "Apache server (Spoke1) private IP — DNAT target + Bastion IpConnect target"
  value       = module.app1_app.apache_private_ip
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

#--- Front Door ---
output "frontdoor_endpoint" {
  description = "Azure Front Door endpoint hostname"
  value       = module.frontdoor.frontdoor_endpoint_hostname
}

#--- Bastion Quick Reference ---
output "bastion_ssh_commands" {
  description = "Quick reference: Bastion SSH commands for Panorama, FW1, FW2 and Apache"
  value       = <<-EOT
    # Panorama
    az network bastion ssh --name ${module.networking.bastion_name} --resource-group ${module.networking.bastion_resource_group} --target-resource-id ${module.panorama.panorama_vm_id} --auth-type password --username panadmin

    # FW1 (Active)   mgmt IP: ${module.firewall.fw1_mgmt_private_ip}
    az network bastion ssh --name ${module.networking.bastion_name} --resource-group ${module.networking.bastion_resource_group} --target-resource-id ${module.firewall.fw1_vm_id} --auth-type password --username panadmin

    # FW2 (Passive)  mgmt IP: ${module.firewall.fw2_mgmt_private_ip}
    az network bastion ssh --name ${module.networking.bastion_name} --resource-group ${module.networking.bastion_resource_group} --target-resource-id ${module.firewall.fw2_vm_id} --auth-type password --username panadmin

    # Apache web server (Spoke1, Ubuntu) — IpConnect via private IP works because Bastion Standard reaches peered VNets
    az network bastion ssh --name ${module.networking.bastion_name} --resource-group ${module.networking.bastion_resource_group} --target-ip-address ${module.app1_app.apache_private_ip} --resource-group ${module.networking.bastion_resource_group} --auth-type password --username panadmin
  EOT
}
