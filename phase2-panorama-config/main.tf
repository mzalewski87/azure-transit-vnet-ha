###############################################################################
# Phase 2 – Panorama Configuration Root Module
# Konfiguruje Panoramę przy użyciu providera panos
###############################################################################

module "panorama_config" {
  source = "../modules/panorama_config"

  panorama_hostname  = var.panorama_hostname
  panorama_username  = var.panorama_username
  panorama_password  = var.panorama_password

  template_name       = var.template_name
  template_stack_name = var.template_stack_name
  device_group_name   = var.device_group_name

  trust_subnet_cidr   = var.trust_subnet_cidr
  untrust_subnet_cidr = var.untrust_subnet_cidr
  spoke1_vnet_cidr    = var.spoke1_vnet_cidr
  spoke2_vnet_cidr    = var.spoke2_vnet_cidr

  apache_server_ip      = var.apache_server_ip
  external_lb_public_ip = var.external_lb_public_ip
}

###############################################################################
# Panorama Commit
# Zatwierdza konfigurację z candidate config do running config w Panoramie.
# WYMAGANE: bez commit, Device Group i Template Stack istnieją tylko w candidate
# config i FW nie może się zarejestrować prawidłowo.
#
# Commit przez Panorama XML API (curl przez aktywny Bastion tunnel 127.0.0.1:44300).
# Uwaga: commit Panoramy NIE pushuje do FW – FW są jeszcze niezarejestrowane.
# Push do FW następuje po Phase 1b przez: Panorama → Commit → Push to Devices.
###############################################################################
resource "null_resource" "panorama_commit" {
  # Wymuszaj ponowny commit gdy zmienią się zasoby panorama_config
  triggers = {
    template_name       = var.template_name
    template_stack_name = var.template_stack_name
    device_group_name   = var.device_group_name
    external_lb_ip      = var.external_lb_public_ip
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      PANORAMA_URL="https://${var.panorama_hostname}:${var.panorama_port}"

      echo "→ Pobieranie API key z Panoramy..."
      API_KEY=$(curl -sk "$PANORAMA_URL/api/" \
        -d "type=keygen" \
        --data-urlencode "user=${var.panorama_username}" \
        --data-urlencode "password=${var.panorama_password}" \
        | grep -oE '<key>[^<]+' | sed 's/<key>//' || true)

      if [ -z "$API_KEY" ]; then
        echo "❌ BŁĄD: Nie można pobrać API key z Panoramy. Sprawdź hasło i połączenie."
        exit 1
      fi

      echo "→ Zatwierdzanie konfiguracji Panoramy (commit)..."
      COMMIT_RESPONSE=$(curl -sk "$PANORAMA_URL/api/" \
        --data-urlencode "type=commit" \
        --data-urlencode "cmd=<commit></commit>" \
        --data-urlencode "key=$API_KEY")

      echo "Odpowiedź commit: $COMMIT_RESPONSE"

      # Sprawdź status commit
      if echo "$COMMIT_RESPONSE" | grep -q 'status="success"'; then
        echo "✅ Commit Panoramy zakończony pomyślnie!"
      elif echo "$COMMIT_RESPONSE" | grep -q 'status="success" code="19"'; then
        echo "✅ Commit: brak zmian do zatwierdzenia (config already committed)."
      else
        echo "⚠️  Commit zainicjowany (może być przetwarzany asynchronicznie)."
        echo "    Sprawdź status: Panorama GUI → Tasks (prawy górny róg)"
      fi
    EOT
  }

  depends_on = [module.panorama_config]
}
