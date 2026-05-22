###############################################################################
# Front Door + WordPress LB Rule Module – Outputs
###############################################################################

output "wordpress_endpoint_hostname" {
  description = "AFD endpoint hostname — the public URL for WordPress"
  value       = azurerm_cdn_frontdoor_endpoint.wordpress.host_name
}

output "wordpress_url" {
  description = "Full HTTPS URL (use this in a browser)"
  value       = "https://${azurerm_cdn_frontdoor_endpoint.wordpress.host_name}"
}

output "external_lb_rule_name" {
  description = "Name of the new LB rule added to the existing External LB"
  value       = azurerm_lb_rule.wordpress_8080.name
}
