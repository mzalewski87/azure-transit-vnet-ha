###############################################################################
# Front Door Module
# Azure Front Door Premium - Global HTTP/HTTPS ingress for application traffic
#
# Traffic flow:
#   Client → Azure Front Door (global anycast) → External LB Public IP
#           → VM-Series (PAN-OS inspection) → Application in Spoke VNet
#
# Components:
#   - Profile:       Front Door Premium (supports WAF, Private Link origins)
#   - Endpoint:      Public-facing hostname (*.z01.azurefd.net)
#   - Origin Group:  Contains the External LB as origin with health probing
#   - Origin:        External LB Public IP (HTTP 80 / HTTPS 443)
#   - Route:         HTTP + HTTPS with HTTPS redirect and caching disabled
#   - Rule Set:      Placeholder for custom rules (headers, redirects, etc.)
###############################################################################

###############################################################################
# Front Door Profile
###############################################################################
resource "azurerm_cdn_frontdoor_profile" "main" {
  name                     = "afd-panos-transit"
  resource_group_name      = var.resource_group_name
  sku_name                 = var.frontdoor_sku
  response_timeout_seconds = 60
  tags                     = var.tags
}

###############################################################################
# Front Door Endpoint
# Provides the public hostname: <name>-<hash>.z01.azurefd.net
###############################################################################
resource "azurerm_cdn_frontdoor_endpoint" "main" {
  name                     = "endpoint-panos-app"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main.id
  enabled                  = true
  tags                     = var.tags
}

###############################################################################
# Origin Group
# Defines load balancing and health probe settings for backend origins
###############################################################################
resource "azurerm_cdn_frontdoor_origin_group" "main" {
  name                     = "og-external-lb"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main.id
  session_affinity_enabled = false

  health_probe {
    interval_in_seconds = var.health_probe_interval_seconds
    path                = var.health_probe_path
    protocol            = "Http" # Probe via HTTP 80 (matches forwarding_protocol)
    request_type        = "HEAD"
  }

  load_balancing {
    additional_latency_in_milliseconds = 50
    sample_size                        = 4
    successful_samples_required        = 3
  }
}

###############################################################################
# Origin - External Load Balancer Public IP
# Front Door connects to this IP to reach VM-Series for traffic forwarding
###############################################################################
resource "azurerm_cdn_frontdoor_origin" "external_lb" {
  name                          = "origin-external-lb"
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.main.id
  enabled                       = true

  # Front Door connects to origin using public IP (not hostname-based TLS verification)
  certificate_name_check_enabled = false

  host_name          = var.external_lb_public_ip
  http_port          = var.origin_http_port
  https_port         = var.origin_https_port
  origin_host_header = var.external_lb_public_ip
  priority           = 1
  weight             = 1000
}

###############################################################################
# Rule Set - placeholder for custom routing rules
# Extend this with request header manipulation, URL rewrites, etc.
###############################################################################
resource "azurerm_cdn_frontdoor_rule_set" "main" {
  name                     = "ruleset1"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main.id
}

###############################################################################
# Route - HTTP and HTTPS traffic to VM-Series via External LB
###############################################################################
resource "azurerm_cdn_frontdoor_route" "main" {
  name                          = "route-http-https-to-fw"
  cdn_frontdoor_endpoint_id     = azurerm_cdn_frontdoor_endpoint.main.id
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.main.id
  cdn_frontdoor_origin_ids      = [azurerm_cdn_frontdoor_origin.external_lb.id]
  cdn_frontdoor_rule_set_ids    = [azurerm_cdn_frontdoor_rule_set.main.id]

  enabled                = true
  forwarding_protocol    = "HttpOnly" # Forward to origin over HTTP (Apache has no SSL)
  https_redirect_enabled = true       # Redirect HTTP clients to HTTPS (AFD terminates TLS)
  patterns_to_match      = ["/*"]
  supported_protocols    = ["Http", "Https"]

  # Caching disabled - firewall/application handles responses directly
  cache {
    query_string_caching_behavior = "IgnoreQueryString"
    compression_enabled           = false
  }

  depends_on = [azurerm_cdn_frontdoor_origin.external_lb]
}
