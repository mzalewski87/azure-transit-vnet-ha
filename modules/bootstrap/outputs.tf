###############################################################################
# Bootstrap Module Outputs
###############################################################################

output "managed_identity_id" {
  description = "User Assigned Managed Identity ID (attached to FW VMs)"
  value       = azurerm_user_assigned_identity.bootstrap.id
}

output "managed_identity_principal_id" {
  description = "Service Principal ID of the Managed Identity"
  value       = azurerm_user_assigned_identity.bootstrap.principal_id
}

###############################################################################
# Per-FW custom_data (base64-encoded init-cfg)
# PAN-OS 10.0+ reads these parameters directly from Azure IMDS on first boot.
###############################################################################

output "fw1_custom_data" {
  description = "FW1 bootstrap custom_data (init-cfg, base64-encoded)"
  value       = base64encode(local_file.fw1_init_cfg.content)
  sensitive   = true
}

output "fw2_custom_data" {
  description = "FW2 bootstrap custom_data (init-cfg, base64-encoded)"
  value       = base64encode(local_file.fw2_init_cfg.content)
  sensitive   = true
}
