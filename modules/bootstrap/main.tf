###############################################################################
# Bootstrap Module
# Azure Storage Account + VM-Series FW Bootstrap Package (Azure File Share)
#
# ZAKRES: Bootstrap SA jest WYŁĄCZNIE dla VM-Series FW (FW1 + FW2).
#         Panorama NIE korzysta z bootstrap – konfiguracja przez Phase 2 (XML API).
#
# Struktura File Share (per dokumentacja PAN-OS bootstrap na Azure):
#   bootstrap/                     ← Azure File Share (SMB)
#     fw1/
#       config/init-cfg.txt        ← FW1 bootstrap config
#       license/authcodes          ← FW1 auth codes (BYOL)
#       content/                   ← (puste, FW pobiera content z CDN)
#       software/                  ← (puste)
#     fw2/
#       config/init-cfg.txt        ← FW2 bootstrap config
#       license/authcodes          ← FW2 auth codes (BYOL)
#       content/                   ← (puste)
#       software/                  ← (puste)
#
# Ref: https://docs.paloaltonetworks.com/vm-series/11-1/vm-series-deployment/bootstrap-the-vm-series-firewall/bootstrap-the-vm-series-firewall-in-azure
###############################################################################

###############################################################################
# User Assigned Managed Identity
# Przypisywana do FW VM – dodatkowa metoda dostępu do SA.
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
# Dostęp: FW mgmt subnet (service endpoint) + operator IP + NAT GW IP
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
  cross_tenant_replication_enabled = false
  tags                            = var.tags

  network_rules {
    default_action             = "Deny"
    bypass                     = ["AzureServices"]
    virtual_network_subnet_ids = var.allowed_subnet_ids
    ip_rules                   = concat(var.terraform_operator_ips, var.nat_gateway_ips)
  }
}

###############################################################################
# Azure File Share (SMB) – wymagane przez PAN-OS bootstrap
# PAN-OS oczekuje Azure File Share, NIE Blob Container.
###############################################################################
resource "azurerm_storage_share" "bootstrap" {
  name                 = "bootstrap"
  storage_account_name = azurerm_storage_account.bootstrap.name
  quota                = 1
}

# RBAC roles for MI
resource "azurerm_role_assignment" "bootstrap_mi_reader" {
  scope                = azurerm_storage_account.bootstrap.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_user_assigned_identity.bootstrap.principal_id
}

resource "azurerm_role_assignment" "bootstrap_mi_file_reader" {
  scope                = azurerm_storage_account.bootstrap.id
  role_definition_name = "Storage File Data SMB Share Reader"
  principal_id         = azurerm_user_assigned_identity.bootstrap.principal_id
}

###############################################################################
# Local files – rendered bootstrap content
# azurerm_storage_share_file wymaga `source` (ścieżka do pliku),
# nie obsługuje `source_content`. Tworzymy pliki lokalnie.
###############################################################################

resource "local_file" "fw1_init_cfg" {
  content = templatefile("${path.module}/templates/init-cfg.txt.tpl", {
    hostname                = "fw1-transit-hub"
    panorama_server         = var.panorama_private_ip
    panorama_template_stack = var.panorama_template_stack
    panorama_device_group   = var.panorama_device_group
    panorama_vm_auth_key    = var.panorama_vm_auth_key
    authcodes               = var.fw_auth_code
  })
  filename = "${path.module}/rendered/fw1-init-cfg.txt"
}

resource "local_file" "fw1_authcodes" {
  content  = var.fw_auth_code != "" ? var.fw_auth_code : "# no authcode"
  filename = "${path.module}/rendered/fw1-authcodes"
}

resource "local_file" "fw2_init_cfg" {
  content = templatefile("${path.module}/templates/init-cfg.txt.tpl", {
    hostname                = "fw2-transit-hub"
    panorama_server         = var.panorama_private_ip
    panorama_template_stack = var.panorama_template_stack
    panorama_device_group   = var.panorama_device_group
    panorama_vm_auth_key    = var.panorama_vm_auth_key
    authcodes               = var.fw_auth_code
  })
  filename = "${path.module}/rendered/fw2-init-cfg.txt"
}

resource "local_file" "fw2_authcodes" {
  content  = var.fw_auth_code != "" ? var.fw_auth_code : "# no authcode"
  filename = "${path.module}/rendered/fw2-authcodes"
}

###############################################################################
# FW1 Bootstrap – directory structure + files
###############################################################################

resource "azurerm_storage_share_directory" "fw1" {
  name             = "fw1"
  storage_share_id = azurerm_storage_share.bootstrap.id
}

resource "azurerm_storage_share_directory" "fw1_config" {
  name             = "fw1/config"
  storage_share_id = azurerm_storage_share.bootstrap.id
  depends_on       = [azurerm_storage_share_directory.fw1]
}

resource "azurerm_storage_share_directory" "fw1_license" {
  name             = "fw1/license"
  storage_share_id = azurerm_storage_share.bootstrap.id
  depends_on       = [azurerm_storage_share_directory.fw1]
}

resource "azurerm_storage_share_directory" "fw1_content" {
  name             = "fw1/content"
  storage_share_id = azurerm_storage_share.bootstrap.id
  depends_on       = [azurerm_storage_share_directory.fw1]
}

resource "azurerm_storage_share_directory" "fw1_software" {
  name             = "fw1/software"
  storage_share_id = azurerm_storage_share.bootstrap.id
  depends_on       = [azurerm_storage_share_directory.fw1]
}

# Upload plików via curl + SAS token (omija SSL proxy issues z az CLI/Python)
# SAS token generowany lokalnie przez Python (brak wywołań sieciowych)
# curl -sk omija corporate SSL interception
resource "null_resource" "fw1_upload_files" {
  triggers = {
    init_cfg_hash  = local_file.fw1_init_cfg.content_md5
    authcodes_hash = local_file.fw1_authcodes.content_md5
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -e
      SA_NAME="${azurerm_storage_account.bootstrap.name}"
      SA_KEY="${azurerm_storage_account.bootstrap.primary_access_key}"
      SHARE="bootstrap"
      MAX_RETRIES=5
      API_VERSION="2022-11-02"

      # Generate Account SAS token locally via Python (no network calls)
      SAS=$(python3 -c "
import hmac, hashlib, base64, datetime, urllib.parse, sys
key = base64.b64decode('${azurerm_storage_account.bootstrap.primary_access_key}')
name = '${azurerm_storage_account.bootstrap.name}'
ver = '2022-11-02'
start = (datetime.datetime.utcnow() - datetime.timedelta(minutes=5)).strftime('%Y-%m-%dT%H:%MZ')
expiry = (datetime.datetime.utcnow() + datetime.timedelta(hours=2)).strftime('%Y-%m-%dT%H:%MZ')
perms = 'rwdlc'
svc = 'f'
rt = 'sco'
sts = '\n'.join([name, perms, svc, rt, start, expiry, '', 'https', ver, '']) + '\n'
sig = base64.b64encode(hmac.new(key, sts.encode('utf-8'), hashlib.sha256).digest()).decode()
print(urllib.parse.urlencode({'sv':ver,'ss':svc,'srt':rt,'sp':perms,'se':expiry,'st':start,'spr':'https','sig':sig}))
")

      BASE_URL="https://$SA_NAME.file.core.windows.net/$SHARE"

      upload_file() {
        local SRC="$1" DEST="$2"
        local FILE_SIZE=$(wc -c < "$SRC" | tr -d ' ')

        for i in $(seq 1 $MAX_RETRIES); do
          # Step 1: Create file (set size, overwrite if exists)
          HTTP1=$(curl -sk -X PUT \
            "$BASE_URL/$DEST?$SAS" \
            -H "x-ms-version: $API_VERSION" \
            -H "x-ms-type: file" \
            -H "x-ms-content-length: $FILE_SIZE" \
            -H "Content-Length: 0" \
            -o /dev/null -w "%%{http_code}" 2>/dev/null)

          if [ "$HTTP1" != "201" ]; then
            echo "  [RETRY $i/$MAX_RETRIES] Create $DEST: HTTP $HTTP1, waiting 30s..."
            sleep 30
            continue
          fi

          # Step 2: Upload content (Put Range)
          HTTP2=$(curl -sk -X PUT \
            "$BASE_URL/$DEST?comp=range&$SAS" \
            -H "x-ms-version: $API_VERSION" \
            -H "x-ms-range: bytes=0-$((FILE_SIZE - 1))" \
            -H "x-ms-write: update" \
            -H "Content-Length: $FILE_SIZE" \
            --data-binary "@$SRC" \
            -o /dev/null -w "%%{http_code}" 2>/dev/null)

          if [ "$HTTP2" = "201" ]; then
            echo "  [OK] Uploaded $DEST ($FILE_SIZE bytes)"
            return 0
          fi

          echo "  [RETRY $i/$MAX_RETRIES] PutRange $DEST: HTTP $HTTP2, waiting 30s..."
          sleep 30
        done
        echo "  [ERROR] Failed to upload $DEST after $MAX_RETRIES retries"
        return 1
      }

      echo "=== Uploading FW1 bootstrap files ==="
      upload_file "${local_file.fw1_init_cfg.filename}" "fw1/config/init-cfg.txt"
      upload_file "${local_file.fw1_authcodes.filename}" "fw1/license/authcodes"
    SCRIPT
  }

  depends_on = [
    azurerm_storage_share_directory.fw1_config,
    azurerm_storage_share_directory.fw1_license,
    time_sleep.wait_for_sa_network_rules,
  ]
}

###############################################################################
# FW2 Bootstrap – directory structure + files
###############################################################################

resource "azurerm_storage_share_directory" "fw2" {
  name             = "fw2"
  storage_share_id = azurerm_storage_share.bootstrap.id
}

resource "azurerm_storage_share_directory" "fw2_config" {
  name             = "fw2/config"
  storage_share_id = azurerm_storage_share.bootstrap.id
  depends_on       = [azurerm_storage_share_directory.fw2]
}

resource "azurerm_storage_share_directory" "fw2_license" {
  name             = "fw2/license"
  storage_share_id = azurerm_storage_share.bootstrap.id
  depends_on       = [azurerm_storage_share_directory.fw2]
}

resource "azurerm_storage_share_directory" "fw2_content" {
  name             = "fw2/content"
  storage_share_id = azurerm_storage_share.bootstrap.id
  depends_on       = [azurerm_storage_share_directory.fw2]
}

resource "azurerm_storage_share_directory" "fw2_software" {
  name             = "fw2/software"
  storage_share_id = azurerm_storage_share.bootstrap.id
  depends_on       = [azurerm_storage_share_directory.fw2]
}

# Upload plików via curl + SAS token (omija SSL proxy issues z az CLI/Python)
resource "null_resource" "fw2_upload_files" {
  triggers = {
    init_cfg_hash  = local_file.fw2_init_cfg.content_md5
    authcodes_hash = local_file.fw2_authcodes.content_md5
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -e
      SA_NAME="${azurerm_storage_account.bootstrap.name}"
      SA_KEY="${azurerm_storage_account.bootstrap.primary_access_key}"
      SHARE="bootstrap"
      MAX_RETRIES=5
      API_VERSION="2022-11-02"

      # Generate Account SAS token locally via Python (no network calls)
      SAS=$(python3 -c "
import hmac, hashlib, base64, datetime, urllib.parse, sys
key = base64.b64decode('${azurerm_storage_account.bootstrap.primary_access_key}')
name = '${azurerm_storage_account.bootstrap.name}'
ver = '2022-11-02'
start = (datetime.datetime.utcnow() - datetime.timedelta(minutes=5)).strftime('%Y-%m-%dT%H:%MZ')
expiry = (datetime.datetime.utcnow() + datetime.timedelta(hours=2)).strftime('%Y-%m-%dT%H:%MZ')
perms = 'rwdlc'
svc = 'f'
rt = 'sco'
sts = '\n'.join([name, perms, svc, rt, start, expiry, '', 'https', ver, '']) + '\n'
sig = base64.b64encode(hmac.new(key, sts.encode('utf-8'), hashlib.sha256).digest()).decode()
print(urllib.parse.urlencode({'sv':ver,'ss':svc,'srt':rt,'sp':perms,'se':expiry,'st':start,'spr':'https','sig':sig}))
")

      BASE_URL="https://$SA_NAME.file.core.windows.net/$SHARE"

      upload_file() {
        local SRC="$1" DEST="$2"
        local FILE_SIZE=$(wc -c < "$SRC" | tr -d ' ')

        for i in $(seq 1 $MAX_RETRIES); do
          # Step 1: Create file (set size, overwrite if exists)
          HTTP1=$(curl -sk -X PUT \
            "$BASE_URL/$DEST?$SAS" \
            -H "x-ms-version: $API_VERSION" \
            -H "x-ms-type: file" \
            -H "x-ms-content-length: $FILE_SIZE" \
            -H "Content-Length: 0" \
            -o /dev/null -w "%%{http_code}" 2>/dev/null)

          if [ "$HTTP1" != "201" ]; then
            echo "  [RETRY $i/$MAX_RETRIES] Create $DEST: HTTP $HTTP1, waiting 30s..."
            sleep 30
            continue
          fi

          # Step 2: Upload content (Put Range)
          HTTP2=$(curl -sk -X PUT \
            "$BASE_URL/$DEST?comp=range&$SAS" \
            -H "x-ms-version: $API_VERSION" \
            -H "x-ms-range: bytes=0-$((FILE_SIZE - 1))" \
            -H "x-ms-write: update" \
            -H "Content-Length: $FILE_SIZE" \
            --data-binary "@$SRC" \
            -o /dev/null -w "%%{http_code}" 2>/dev/null)

          if [ "$HTTP2" = "201" ]; then
            echo "  [OK] Uploaded $DEST ($FILE_SIZE bytes)"
            return 0
          fi

          echo "  [RETRY $i/$MAX_RETRIES] PutRange $DEST: HTTP $HTTP2, waiting 30s..."
          sleep 30
        done
        echo "  [ERROR] Failed to upload $DEST after $MAX_RETRIES retries"
        return 1
      }

      echo "=== Uploading FW2 bootstrap files ==="
      upload_file "${local_file.fw2_init_cfg.filename}" "fw2/config/init-cfg.txt"
      upload_file "${local_file.fw2_authcodes.filename}" "fw2/license/authcodes"
    SCRIPT
  }

  depends_on = [
    azurerm_storage_share_directory.fw2_config,
    azurerm_storage_share_directory.fw2_license,
    time_sleep.wait_for_sa_network_rules,
  ]
}

###############################################################################
# Sleep after SA creation to allow network_rules propagation
###############################################################################
resource "time_sleep" "wait_for_sa_network_rules" {
  depends_on      = [azurerm_storage_account.bootstrap]
  create_duration = "60s"
}
