###############################################################################
# Panorama AKS Rules Module – Outputs
###############################################################################

output "fqdn_edl_name" {
  description = "Panorama EDL object name for AKS FQDN list"
  value       = panos_panorama_edl.aks_fqdn.name
}

output "ips_edl_name" {
  description = "Panorama EDL object name for AKS IP list"
  value       = panos_panorama_edl.aks_ips.name
}

output "aks_spoke_address_object" {
  description = "Address object name for AKS spoke3 CIDR"
  value       = panos_panorama_address_object.aks_spoke.name
}

output "wordpress_dnat_rule" {
  description = "NAT rule name for WordPress inbound DNAT"
  value       = "DNAT-Inbound-WordPress"
}
