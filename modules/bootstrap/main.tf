###############################################################################
# Bootstrap Module
# Azure Storage Account + VM-Series FW Bootstrap Package
#
# ZAKRES: Bootstrap SA jest WYŁĄCZNIE dla VM-Series FW (FW1 + FW2).
#         Panorama używa bezpośredniej treści init-cfg w customData (nie SA pointer).
#
# Struktura SA:
#   bootstrap/                     ← container
#     fw1/
#       config/init-cfg.txt        ← FW1 bootstrap config
#       license/authcodes          ← FW1 auth codes
#       content/                   ← (puste, FW pobiera content z CDN)
#       software/                  ← (puste)
#     fw2/
#       config/init-cfg.txt        ← FW2 bootstrap config
#       license/authcodes          ← FW2 auth codes
###############################################################################

###############################################################################
# User Assigned Managed Identity
# Przypisywana do FW VM – pozwala na dostęp do SA bez access-key w customData.
# Alternatywnie FW może używać access-key (mniej bezpieczne, ale prostsze).
# Tu stosujemy MI dla poprawności security baseline.
###############################################################################
resource "azurerm_user_assigned_identity" "bootstrap" {
  name                = "id-panos-bootstrap"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

###############################################################################
# Storage Account
# Network rules: default_action=Deny (Azure Policy compliance)
# Dostęp: FW mgmt subnet (service endpoint) + operator IP (dla blob upload)
###############################################################################
resource "random_string" "sa_suffix" {
  length  = 8
  special = false
  upper   = false
}

resource "azurerm_storage_account" "bootstrap" {
  name                            = "sapanosbstrap${random_string.sa_suffix.result}"
  resource_group_name             = var.resource_group_name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  # Azure Policy: "Storage accounts should prevent cross tenant object replication"
  # policyDefinition/92a89a79-6c52-4a7e-a03f-61306fc49312
  cross_tenant_replication_enabled = false
  tags                            = var.tags

  network_rules {
    default_action             = "Deny"
    bypass                     = ["AzureServices"]
    virtual_network_subnet_ids = var.allowed_subnet_ids
    ip_rules                   = var.terraform_operator_ips
  }

  lifecycle {
    ignore_changes = [network_rules]
  }
}

# Bootstrap container
resource "azurerm_storage_container" "bootstrap" {
  name                  = "bootstrap"
  storage_account_name  = azurerm_storage_account.bootstrap.name
  container_access_type = "private"
}

# Storage Blob Data Reader role for MI
resource "azurerm_role_assignment" "bootstrap_mi_reader" {
  scope                = azurerm_storage_account.bootstrap.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_user_assigned_identity.bootstrap.principal_id
}

###############################################################################
# FW1 Bootstrap Files
###############################################################################

resource "azurerm_storage_blob" "fw1_init_cfg" {
  name                   = "fw1/config/init-cfg.txt"
  storage_account_name   = azurerm_storage_account.bootstrap.name
  storage_container_name = azurerm_storage_container.bootstrap.name
  type                   = "Block"
  source_content = templatefile("${path.module}/templates/init-cfg.txt.tpl", {
    hostname               = "fw1-transit-hub"
    panorama_server        = var.panorama_private_ip
    panorama_template_stack = var.panorama_template_stack
    panorama_device_group  = var.panorama_device_group
    panorama_vm_auth_key   = var.panorama_vm_auth_key
    authcodes              = var.fw_auth_code
  })
}

resource "azurerm_storage_blob" "fw1_authcodes" {
  name                   = "fw1/license/authcodes"
  storage_account_name   = azurerm_storage_account.bootstrap.name
  storage_container_name = azurerm_storage_container.bootstrap.name
  type                   = "Block"
  source_content         = var.fw_auth_code != "" ? var.fw_auth_code : "# no authcode"
}

# Required empty dirs (FW bootstrap expects these paths to exist)
resource "azurerm_storage_blob" "fw1_content_placeholder" {
  name                   = "fw1/content/.keep"
  storage_account_name   = azurerm_storage_account.bootstrap.name
  storage_container_name = azurerm_storage_container.bootstrap.name
  type                   = "Block"
  source_content         = ""
}

resource "azurerm_storage_blob" "fw1_software_placeholder" {
  name                   = "fw1/software/.keep"
  storage_account_name   = azurerm_storage_account.bootstrap.name
  storage_container_name = azurerm_storage_container.bootstrap.name
  type                   = "Block"
  source_content         = ""
}

###############################################################################
# FW2 Bootstrap Files
###############################################################################

resource "azurerm_storage_blob" "fw2_init_cfg" {
  name                   = "fw2/config/init-cfg.txt"
  storage_account_name   = azurerm_storage_account.bootstrap.name
  storage_container_name = azurerm_storage_container.bootstrap.name
  type                   = "Block"
  source_content = templatefile("${path.module}/templates/init-cfg.txt.tpl", {
    hostname               = "fw2-transit-hub"
    panorama_server        = var.panorama_private_ip
    panorama_template_stack = var.panorama_template_stack
    panorama_device_group  = var.panorama_device_group
    panorama_vm_auth_key   = var.panorama_vm_auth_key
    authcodes              = var.fw_auth_code
  })
}

resource "azurerm_storage_blob" "fw2_authcodes" {
  name                   = "fw2/license/authcodes"
  storage_account_name   = azurerm_storage_account.bootstrap.name
  storage_container_name = azurerm_storage_container.bootstrap.name
  type                   = "Block"
  source_content         = var.fw_auth_code != "" ? var.fw_auth_code : "# no authcode"
}

resource "azurerm_storage_blob" "fw2_content_placeholder" {
  name                   = "fw2/content/.keep"
  storage_account_name   = azurerm_storage_account.bootstrap.name
  storage_container_name = azurerm_storage_container.bootstrap.name
  type                   = "Block"
  source_content         = ""
}

resource "azurerm_storage_blob" "fw2_software_placeholder" {
  name                   = "fw2/software/.keep"
  storage_account_name   = azurerm_storage_account.bootstrap.name
  storage_container_name = azurerm_storage_container.bootstrap.name
  type                   = "Block"
  source_content         = ""
}

###############################################################################
# Sleep after SA creation to allow network_rules propagation
# (Azure may take up to 30s to apply SA network ACLs)
###############################################################################
resource "time_sleep" "wait_for_sa_network_rules" {
  depends_on      = [azurerm_storage_account.bootstrap]
  create_duration = "60s"
}
