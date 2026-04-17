###############################################################################
# Front Door Module Outputs
###############################################################################

output "frontdoor_profile_id" {
  description = "Azure Front Door profile resource ID"
  value       = azurerm_cdn_frontdoor_profile.main.id
}

output "frontdoor_endpoint_id" {
  description = "Azure Front Door endpoint resource ID"
  value       = azurerm_cdn_frontdoor_endpoint.main.id
}

output "frontdoor_endpoint_hostname" {
  description = "Azure Front Door endpoint public hostname (use this for application DNS)"
  value       = azurerm_cdn_frontdoor_endpoint.main.host_name
}

output "frontdoor_origin_group_id" {
  description = "Origin group resource ID"
  value       = azurerm_cdn_frontdoor_origin_group.main.id
}
