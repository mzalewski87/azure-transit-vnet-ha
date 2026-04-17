###############################################################################
# Routing Module Outputs
###############################################################################

output "spoke1_route_table_id" {
  description = "Route Table resource ID for Spoke 1 workload subnet"
  value       = azurerm_route_table.spoke1.id
}

output "spoke2_route_table_id" {
  description = "Route Table resource ID for Spoke 2 workload subnet"
  value       = azurerm_route_table.spoke2.id
}

output "spoke1_route_table_name" {
  description = "Route Table name for Spoke 1"
  value       = azurerm_route_table.spoke1.name
}

output "spoke2_route_table_name" {
  description = "Route Table name for Spoke 2"
  value       = azurerm_route_table.spoke2.name
}
