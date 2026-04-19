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
  description = "base64-encoded custom_data for FW1 pointing to bootstrap storage (account key auth)"
  sensitive   = true
  # Format wymagany przez PAN-OS 11.x dla Azure Blob Storage z kluczem konta:
  #   access-key=<key>  – jawny klucz SA (niezawodny, bez zależności od timing MI)
  #   file-share=<container>  – nazwa kontenera Blob Storage
  #   share-directory=<fw1>   – podkatalog wewnątrz kontenera
  #
  # Dlaczego klucz SA zamiast Managed Identity (access-key= puste):
  #   Managed Identity wymaga propagacji roli (5-15 min) zanim FW może czytać blobs.
  #   FW bootuje już po ~2-5 min → czyta bootstrap zanim MI role jest propagowana → fail.
  #   Jawny klucz SA działa natychmiastowo i niezawodnie.
  #
  # Bezpieczeństwo: klucz SA jest w VM custom_data (dostępny dla admina VM).
  #   Dla produkcji: użyj SAS token z krótkim TTL. Dla demo: klucz SA jest akceptowalny.
  value = base64encode(join("\n", [
    "storage-account=${azurerm_storage_account.bootstrap.name}",
    "file-share=${azurerm_storage_container.bootstrap.name}",
    "share-directory=fw1",
    "access-key=${azurerm_storage_account.bootstrap.primary_access_key}",
  ]))
}

output "fw2_custom_data" {
  description = "base64-encoded custom_data for FW2 pointing to bootstrap storage (account key auth)"
  sensitive   = true
  value = base64encode(join("\n", [
    "storage-account=${azurerm_storage_account.bootstrap.name}",
    "file-share=${azurerm_storage_container.bootstrap.name}",
    "share-directory=fw2",
    "access-key=${azurerm_storage_account.bootstrap.primary_access_key}",
  ]))
}

output "panorama_custom_data" {
  description = <<-EOT
    base64-encoded custom_data dla Panoramy wskazujący na bootstrap SA.
    Panorama jest PAN-OS i czyta bootstrap IDENTYCZNIE jak VM-Series FW:
      customData → wskaźnik do SA → SA:bootstrap/panorama/config/init-cfg.txt
    Format: storage-account + file-share + share-directory + access-key
    Uwaga: PAN-OS IGNORUJE bezpośrednią treść init-cfg w customData!
  EOT
  sensitive = true
  value = base64encode(join("\n", [
    "storage-account=${azurerm_storage_account.bootstrap.name}",
    "file-share=${azurerm_storage_container.bootstrap.name}",
    "share-directory=panorama",
    "access-key=${azurerm_storage_account.bootstrap.primary_access_key}",
  ]))
}
