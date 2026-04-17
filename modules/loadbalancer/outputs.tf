###############################################################################
# Load Balancer Module Outputs
###############################################################################

output "external_lb_id" {
  description = "External (Public) Load Balancer resource ID"
  value       = azurerm_lb.external.id
}

output "external_lb_backend_pool_id" {
  description = "External LB backend address pool ID (used for NIC associations)"
  value       = azurerm_lb_backend_address_pool.external.id
}

output "external_lb_frontend_ip" {
  description = "External LB frontend IP configuration name"
  value       = "fe-external-lb"
}

output "internal_lb_id" {
  description = "Internal Load Balancer resource ID"
  value       = azurerm_lb.internal.id
}

output "internal_lb_backend_pool_id" {
  description = "Internal LB backend address pool ID (used for NIC associations)"
  value       = azurerm_lb_backend_address_pool.internal.id
}

output "internal_lb_private_ip" {
  description = "Internal LB frontend private IP - this is the UDR next-hop address for spoke subnets"
  value       = azurerm_lb.internal.frontend_ip_configuration[0].private_ip_address
}
