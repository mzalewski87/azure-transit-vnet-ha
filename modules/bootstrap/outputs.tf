###############################################################################
# Bootstrap Module Outputs
###############################################################################

output "storage_account_name" {
  description = "Bootstrap storage account name"
  value       = azurerm_storage_account.bootstrap.name
}

output "storage_account_id" {
  description = "Bootstrap storage account resource ID"
  value       = azurerm_storage_account.bootstrap.id
}

output "container_name" {
  description = "Bootstrap blob container name"
  value       = azurerm_storage_container.bootstrap.name
}

output "managed_identity_id" {
  description = "User Assigned Managed Identity resource ID (assign to FW VMs)"
  value       = azurerm_user_assigned_identity.fw_bootstrap.id
}

output "managed_identity_client_id" {
  description = "User Assigned Managed Identity client ID"
  value       = azurerm_user_assigned_identity.fw_bootstrap.client_id
}

output "fw1_custom_data" {
  description = "base64-encoded custom_data for FW1 pointing to bootstrap storage (Managed Identity)"
  sensitive   = true
  # Format wymagany przez PAN-OS 11.x dla Azure Blob Storage z Managed Identity:
  #   access-key=  (puste) – sygnalizuje PAN-OS aby użył Managed Identity do autentykacji
  #   NIE używaj storage-account-key=None (błędna nazwa parametru + błędna wartość)
  value = base64encode(join("\n", [
    "storage-account=${azurerm_storage_account.bootstrap.name}",
    "file-share=${azurerm_storage_container.bootstrap.name}",
    "share-directory=fw1",
    "access-key=",
  ]))
}

output "fw2_custom_data" {
  description = "base64-encoded custom_data for FW2 pointing to bootstrap storage (Managed Identity)"
  sensitive   = true
  value = base64encode(join("\n", [
    "storage-account=${azurerm_storage_account.bootstrap.name}",
    "file-share=${azurerm_storage_container.bootstrap.name}",
    "share-directory=fw2",
    "access-key=",
  ]))
}
