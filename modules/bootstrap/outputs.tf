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

# FW bootstrap storage pointers (base64-encoded, used as customData/userData for VM-Series FW)
#
# Format per dokumentacja PAN-OS bootstrap na Azure:
#   storage-account  = SA name
#   access-key       = SA primary access key (poprawna nazwa pola per PANW docs)
#   file-share       = Azure File Share name
#   share-directory  = subfolder per FW (fw1 / fw2)
#
# Ref: https://docs.paloaltonetworks.com/vm-series/11-1/vm-series-deployment/bootstrap-the-vm-series-firewall/bootstrap-the-vm-series-firewall-in-azure

output "fw1_custom_data" {
  description = "FW1 bootstrap custom_data (storage pointer, base64-encoded)"
  value       = base64encode(join("\n", [
    "storage-account=${azurerm_storage_account.bootstrap.name}",
    "access-key=${azurerm_storage_account.bootstrap.primary_access_key}",
    "file-share=${azurerm_storage_share.bootstrap.name}",
    "share-directory=fw1",
  ]))
  sensitive = true
}

output "fw2_custom_data" {
  description = "FW2 bootstrap custom_data (storage pointer, base64-encoded)"
  value       = base64encode(join("\n", [
    "storage-account=${azurerm_storage_account.bootstrap.name}",
    "access-key=${azurerm_storage_account.bootstrap.primary_access_key}",
    "file-share=${azurerm_storage_share.bootstrap.name}",
    "share-directory=fw2",
  ]))
  sensitive = true
}
