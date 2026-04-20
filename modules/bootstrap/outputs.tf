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

# FW bootstrap storage pointers (base64-encoded, used as customData for VM-Series FW)
output "fw1_custom_data" {
  description = "FW1 bootstrap custom_data (storage pointer, base64-encoded)"
  value       = base64encode(join("\n", [
    "storage-account=${azurerm_storage_account.bootstrap.name}",
    "file-share=${azurerm_storage_container.bootstrap.name}",
    "share-directory=fw1",
    "access-key=${azurerm_storage_account.bootstrap.primary_access_key}",
  ]))
  sensitive = true
}

output "fw2_custom_data" {
  description = "FW2 bootstrap custom_data (storage pointer, base64-encoded)"
  value       = base64encode(join("\n", [
    "storage-account=${azurerm_storage_account.bootstrap.name}",
    "file-share=${azurerm_storage_container.bootstrap.name}",
    "share-directory=fw2",
    "access-key=${azurerm_storage_account.bootstrap.primary_access_key}",
  ]))
  sensitive = true
}
