###############################################################################
# Bootstrap Module Outputs
###############################################################################

output "storage_account_name" {
  description = "Bootstrap Storage Account name"
  value       = azurerm_storage_account.bootstrap.name
}

output "storage_account_id" {
  description = "Bootstrap Storage Account resource ID"
  value       = azurerm_storage_account.bootstrap.id
}

output "managed_identity_id" {
  description = "User Assigned Managed Identity ID (assigned to FW VMs for SA access)"
  value       = azurerm_user_assigned_identity.bootstrap.id
}

output "managed_identity_principal_id" {
  description = "Service Principal ID of the Managed Identity"
  value       = azurerm_user_assigned_identity.bootstrap.principal_id
}

# FW bootstrap custom_data (base64-encoded init-cfg, used as customData/userData)
#
# APPROACH: Direct init-cfg in custom_data (no file share upload needed)
# PAN-OS 10.0+ reads init-cfg parameters directly from custom_data/userData.
# This eliminates the need to upload files to Azure File Share data plane,
# which is blocked by corporate SSL proxy.
#
# All bootstrap parameters (Panorama, licensing, DNS, NTP) are embedded
# directly. PAN-OS reads them from Azure IMDS on first boot.
#
# Ref: https://docs.paloaltonetworks.com/vm-series/11-1/vm-series-deployment/bootstrap-the-vm-series-firewall/bootstrap-the-vm-series-firewall-in-azure

output "fw1_custom_data" {
  description = "FW1 bootstrap custom_data (init-cfg params, base64-encoded)"
  value       = base64encode(local_file.fw1_init_cfg.content)
  sensitive   = true
}

output "fw2_custom_data" {
  description = "FW2 bootstrap custom_data (init-cfg params, base64-encoded)"
  value       = base64encode(local_file.fw2_init_cfg.content)
  sensitive   = true
}
