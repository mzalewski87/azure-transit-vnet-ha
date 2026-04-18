###############################################################################
# Bootstrap Module
# Azure Storage Account with VM-Series bootstrap package
#
# Bootstrap directory structure per firewall:
#   bootstrap/
#   ├── fw1/
#   │   ├── config/init-cfg.txt   (Panorama registration + hostname)
#   │   └── license/authcodes     (VM-Series BYOL auth code)
#   └── fw2/
#       ├── config/init-cfg.txt
#       └── license/authcodes
#
# VM-Series reads bootstrap via custom_data pointing to storage account.
# Managed Identity (User Assigned) is used for secure access (no static keys).
#
# Azure Policy compliance:
#   - cross_tenant_replication_enabled = false
#   - network_rules: default_action = Deny + service endpoint on mgmt subnet
#   - terraform_operator_ip: add your public IP to allow blob upload from Terraform
###############################################################################

resource "random_string" "sa_suffix" {
  length  = 6
  upper   = false
  special = false
}

###############################################################################
# Bootstrap Storage Account
# Policy-compliant: network restricted, no cross-tenant replication
###############################################################################
resource "azurerm_storage_account" "bootstrap" {
  name                     = "sapanosbstrap${random_string.sa_suffix.result}"
  resource_group_name      = var.resource_group_name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  # Disable public blob access - Managed Identity is used for authentication
  allow_nested_items_to_be_public = false
  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"

  # Azure Policy: "Storage accounts should prevent cross tenant object replication"
  cross_tenant_replication_enabled = false

  # UWAGA: network_rules NIE są tutaj – są w osobnym zasobie poniżej.
  # Powód: inline network_rules blokuje Terraform zanim uploady blobów się zakończą.
  # Rozwiązanie: azurerm_storage_account_network_rules z depends_on na wszystkich blobsach.
  tags = var.tags
}

resource "azurerm_storage_container" "bootstrap" {
  name                  = "bootstrap"
  storage_account_name  = azurerm_storage_account.bootstrap.name
  container_access_type = "private"
}

###############################################################################
# User Assigned Managed Identity
# VM-Series FW1 and FW2 will be assigned this identity to access bootstrap blobs
###############################################################################
resource "azurerm_user_assigned_identity" "fw_bootstrap" {
  name                = "id-fw-bootstrap"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# Grant the managed identity read access to the bootstrap blobs
resource "azurerm_role_assignment" "fw_bootstrap_reader" {
  scope                = azurerm_storage_account.bootstrap.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_user_assigned_identity.fw_bootstrap.principal_id
}

###############################################################################
# Bootstrap blobs - FW1
###############################################################################

# FW1 init-cfg.txt: Panorama registration, hostname, DHCP settings
resource "azurerm_storage_blob" "fw1_init_cfg" {
  name                   = "fw1/config/init-cfg.txt"
  storage_account_name   = azurerm_storage_account.bootstrap.name
  storage_container_name = azurerm_storage_container.bootstrap.name
  type                   = "Block"
  source_content = templatefile("${path.module}/templates/init-cfg.txt.tpl", {
    hostname                = var.fw1_hostname
    panorama_server         = var.panorama_private_ip
    panorama_vm_auth_key    = var.panorama_vm_auth_key
    panorama_template_stack = var.panorama_template_stack
    panorama_device_group   = var.panorama_device_group
  })
}

# FW1 authcodes: BYOL license auth code
resource "azurerm_storage_blob" "fw1_authcodes" {
  name                   = "fw1/license/authcodes"
  storage_account_name   = azurerm_storage_account.bootstrap.name
  storage_container_name = azurerm_storage_container.bootstrap.name
  type                   = "Block"
  source_content         = var.fw_auth_code
}

# FW1 empty placeholder files (required by PAN-OS bootstrap process)
resource "azurerm_storage_blob" "fw1_software_placeholder" {
  name                   = "fw1/software/.placeholder"
  storage_account_name   = azurerm_storage_account.bootstrap.name
  storage_container_name = azurerm_storage_container.bootstrap.name
  type                   = "Block"
  source_content         = ""
}

resource "azurerm_storage_blob" "fw1_content_placeholder" {
  name                   = "fw1/content/.placeholder"
  storage_account_name   = azurerm_storage_account.bootstrap.name
  storage_container_name = azurerm_storage_container.bootstrap.name
  type                   = "Block"
  source_content         = ""
}

###############################################################################
# Bootstrap blobs - FW2
###############################################################################

resource "azurerm_storage_blob" "fw2_init_cfg" {
  name                   = "fw2/config/init-cfg.txt"
  storage_account_name   = azurerm_storage_account.bootstrap.name
  storage_container_name = azurerm_storage_container.bootstrap.name
  type                   = "Block"
  source_content = templatefile("${path.module}/templates/init-cfg.txt.tpl", {
    hostname                = var.fw2_hostname
    panorama_server         = var.panorama_private_ip
    panorama_vm_auth_key    = var.panorama_vm_auth_key
    panorama_template_stack = var.panorama_template_stack
    panorama_device_group   = var.panorama_device_group
  })
}

resource "azurerm_storage_blob" "fw2_authcodes" {
  name                   = "fw2/license/authcodes"
  storage_account_name   = azurerm_storage_account.bootstrap.name
  storage_container_name = azurerm_storage_container.bootstrap.name
  type                   = "Block"
  source_content         = var.fw_auth_code
}

resource "azurerm_storage_blob" "fw2_software_placeholder" {
  name                   = "fw2/software/.placeholder"
  storage_account_name   = azurerm_storage_account.bootstrap.name
  storage_container_name = azurerm_storage_container.bootstrap.name
  type                   = "Block"
  source_content         = ""
}

resource "azurerm_storage_blob" "fw2_content_placeholder" {
  name                   = "fw2/content/.placeholder"
  storage_account_name   = azurerm_storage_account.bootstrap.name
  storage_container_name = azurerm_storage_container.bootstrap.name
  type                   = "Block"
  source_content         = ""
}

###############################################################################
# Storage Account Network Rules
# WAŻNE: Muszą być PO uploadzie blobów (depends_on na wszystkich blobsach).
# Inline network_rules w azurerm_storage_account blokuje Terraform przed uploadem.
#
# Działanie:
#   - default_action = Deny: blokuje cały dostęp po wdrożeniu
#   - bypass = AzureServices: pozwala FW (Managed Identity) czytać boostrap blobs
#   - virtual_network_subnet_ids: mgmt subnet z service endpoint Microsoft.Storage
#   - ip_rules: IP operatora Terraform (do ewentualnych późniejszych zmian blobów)
###############################################################################
resource "azurerm_storage_account_network_rules" "bootstrap" {
  storage_account_id         = azurerm_storage_account.bootstrap.id
  default_action             = "Deny"
  bypass                     = ["AzureServices", "Logging", "Metrics"]
  virtual_network_subnet_ids = var.allowed_subnet_ids
  ip_rules                   = compact(var.terraform_operator_ips)

  depends_on = [
    azurerm_storage_blob.fw1_init_cfg,
    azurerm_storage_blob.fw1_authcodes,
    azurerm_storage_blob.fw1_software_placeholder,
    azurerm_storage_blob.fw1_content_placeholder,
    azurerm_storage_blob.fw2_init_cfg,
    azurerm_storage_blob.fw2_authcodes,
    azurerm_storage_blob.fw2_software_placeholder,
    azurerm_storage_blob.fw2_content_placeholder,
  ]
}
