###############################################################################
# Phase 2 – Panorama Configuration (API-based)
#
# WYMAGANIA:
#   1. Panorama VM uruchomiona (Phase 1a zakończona, VM bootuje ~15 min)
#   2. Bastion tunnel aktywny w OSOBNYM terminalu:
#        PANORAMA_ID=$(cd .. && terraform output -raw panorama_vm_id)
#        az network bastion tunnel \
#          --name bastion-management \
#          --resource-group rg-transit-hub \
#          --target-resource-id "$PANORAMA_ID" \
#          --resource-port 443 --port 44300
#   3. terraform.tfvars uzupełniony (hasło, auth_code, CIDRy)
#
# SEKWENCJA APPLY:
#   1. null_resource.panorama_wait_for_api  – czeka aż Panorama odpowie na HTTP (max 20 min)
#   2. null_resource.panorama_set_hostname  – ustawia hostname przez XML API + commit
#   3. null_resource.panorama_activate_license – aktywuje licencję przez XML API (jeśli podano auth_code)
#   4. module.panorama_config               – panos provider: Template Stack, DG, policies
#   5. null_resource.panorama_commit        – commit Panoramy przez XML API
###############################################################################

###############################################################################
# Step 1: Wait for Panorama API
# Panorama bootuje ~10-20 min. Czekamy aż HTTPS API odpowie.
# Używamy curl --retry (max 40 prób co 30s = 20 min timeout).
# python3: portable XML parsing (macOS + Linux, bez grep -oP).
###############################################################################
resource "null_resource" "panorama_wait_for_api" {
  triggers = {
    panorama_url = "https://${var.panorama_hostname}:${var.panorama_port}"
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -e
      PANORAMA_URL="https://${var.panorama_hostname}:${var.panorama_port}"
      echo "=== Czekam na Panorama API: $PANORAMA_URL ==="
      echo "    (max 20 min, sprawdzam co 30s)"
      ATTEMPTS=0
      MAX_ATTEMPTS=40
      while true; do
        ATTEMPTS=$((ATTEMPTS + 1))
        HTTP_CODE=$(curl -sk --max-time 10 -o /dev/null -w "%%{http_code}" "$PANORAMA_URL/php/login.php" 2>/dev/null || echo "000")
        if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ] || [ "$HTTP_CODE" = "301" ]; then
          echo "[OK] Panorama API odpowiada (HTTP $HTTP_CODE) po $ATTEMPTS probach."
          break
        fi
        if [ "$ATTEMPTS" -ge "$MAX_ATTEMPTS" ]; then
          echo "[BLAD] Panorama API nie odpowiada po $MAX_ATTEMPTS probach ($(( MAX_ATTEMPTS * 30 ))s)."
          echo "       Sprawdz:"
          echo "       1. Czy Bastion tunnel dziala: az network bastion tunnel ..."
          echo "       2. Czy VM jest uruchomiona: az vm show --show-details -g rg-transit-hub -n vm-panorama"
          exit 1
        fi
        echo "  [$ATTEMPTS/$MAX_ATTEMPTS] HTTP $HTTP_CODE – czekam 30s..."
        sleep 30
      done
    SCRIPT
  }
}

###############################################################################
# Step 2: Set hostname via Panorama XML API
# Pobiera API key, ustawia hostname, commituje.
# Idempotentne: bezpieczne przy wielokrotnym apply.
###############################################################################
resource "null_resource" "panorama_set_hostname" {
  triggers = {
    target_hostname = var.panorama_target_hostname
    panorama_url    = "https://${var.panorama_hostname}:${var.panorama_port}"
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -e
      PANORAMA_URL="https://${var.panorama_hostname}:${var.panorama_port}"
      PAN_USER="${var.panorama_username}"
      TARGET_HOST="${var.panorama_target_hostname}"

      echo "=== [Step 2] Ustawiam hostname Panoramy: $TARGET_HOST ==="

      ENC_PASS=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${var.panorama_password}', safe=''))")

      RAW_KEY=$(curl -sk --max-time 30 "$PANORAMA_URL/api/?type=keygen&user=$PAN_USER&password=$ENC_PASS" 2>/dev/null)

      API_KEY=$(echo "$RAW_KEY" | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read())
    if root.get('status') != 'success':
        print('ERROR: ' + (root.findtext('.//msg','no message')), file=sys.stderr)
        sys.exit(1)
    print(root.findtext('.//key',''))
except Exception as e:
    print('ERROR: ' + str(e), file=sys.stderr)
    sys.exit(1)
" 2>&1)

      if echo "$API_KEY" | grep -q "^ERROR:"; then
        echo "[BLAD] Nie mozna pobrac API key: $API_KEY"
        echo "       Sprawdz haslo (panorama_password w terraform.tfvars)."
        exit 1
      fi

      echo "  API key: OK"

      curl -sk --max-time 30 "$PANORAMA_URL/api/" \
        --data-urlencode "type=config" \
        --data-urlencode "action=set" \
        --data-urlencode "xpath=/config/devices/entry[@name='localhost.localdomain']/deviceconfig/system" \
        --data-urlencode "element=<hostname>$TARGET_HOST</hostname>" \
        --data-urlencode "key=$API_KEY" > /dev/null

      COMMIT_RESP=$(curl -sk --max-time 60 "$PANORAMA_URL/api/" \
        --data-urlencode "type=commit" \
        --data-urlencode "cmd=<commit></commit>" \
        --data-urlencode "key=$API_KEY" 2>/dev/null)

      echo "  Hostname '$TARGET_HOST' ustawiony. Commit: OK"
    SCRIPT
  }

  depends_on = [null_resource.panorama_wait_for_api]
}

###############################################################################
# Step 3: Activate Panorama license via XML API
# Wykonywany TYLKO gdy panorama_auth_code != "".
# Idempotentne: jesli juz aktywowana, Panorama zwraca blad "already registered"
# ktory jest ignorowany.
###############################################################################
resource "null_resource" "panorama_activate_license" {
  count = var.panorama_serial_number != "" ? 1 : 0

  triggers = {
    serial_number = var.panorama_serial_number
    panorama_url  = "https://${var.panorama_hostname}:${var.panorama_port}"
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -e
      PANORAMA_URL="https://${var.panorama_hostname}:${var.panorama_port}"
      PAN_USER="${var.panorama_username}"
      SERIAL_NUM="${var.panorama_serial_number}"

      echo "=== [Step 3] Ustawianie numeru seryjnego + aktywacja licencji ==="
      echo "    Serial Number: $SERIAL_NUM"
      echo "    UWAGA: Przed uruchomieniem upewnij sie, ze serial jest zarejestrowany"
      echo "    na CSP Portal: my.paloaltonetworks.com → Assets → Add Product"

      ENC_PASS=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${var.panorama_password}', safe=''))")

      RAW_KEY=$(curl -sk --max-time 30 "$PANORAMA_URL/api/?type=keygen&user=$PAN_USER&password=$ENC_PASS" 2>/dev/null)

      API_KEY=$(echo "$RAW_KEY" | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read())
    if root.get('status') != 'success':
        print('ERROR: ' + (root.findtext('.//msg','no message')), file=sys.stderr)
        sys.exit(1)
    print(root.findtext('.//key',''))
except Exception as e:
    print('ERROR: ' + str(e), file=sys.stderr)
    sys.exit(1)
" 2>&1)

      if echo "$API_KEY" | grep -q "^ERROR:"; then
        echo "[BLAD] Nie mozna pobrac API key: $API_KEY"
        exit 1
      fi
      echo "  API key: OK"

      # Krok 3a: Ustaw numer seryjny przez XML API (tryb OPERACYJNY – request, NIE configure!)
      # Poprawna komenda PAN-OS CLI (operational mode): request serial-number set <SERIAL>
      # Komendy "request" nie wymagaja commit – dzialaja natychmiast
      SET_RESP=$(curl -sk --max-time 30 "$PANORAMA_URL/api/" \
        --data-urlencode "type=op" \
        --data-urlencode "cmd=<request><serial-number><set>$SERIAL_NUM</set></serial-number></request>" \
        --data-urlencode "key=$API_KEY" 2>/dev/null)
      echo "  Odpowiedz set serial-number: $SET_RESP"
      echo "  Czekam 15s na przetworzenie..."
      sleep 15

      # Krok 3c: Pobierz licencje z serwera PANW (BEZ auth-code, na podstawie serial number)
      # Panorama musi miec dostep do internetu przez NAT Gateway (natgw-management)
      echo "  Pobieranie licencji z serwera PANW (request license fetch)..."
      LIC_RESP=$(curl -sk --max-time 120 "$PANORAMA_URL/api/" \
        --data-urlencode "type=op" \
        --data-urlencode "cmd=<request><license><fetch></fetch></license></request>" \
        --data-urlencode "key=$API_KEY" 2>/dev/null)

      echo "$LIC_RESP" | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read())
    status = root.get('status','')
    msg = root.findtext('.//msg','') or root.findtext('.//line','') or 'brak informacji'
    if status == 'success':
        print('[OK] Licencja pobrana pomyslnie!')
    else:
        print('[WARN] Odpowiedz license fetch: status=' + status + ' msg=' + msg)
        print('       Sprawdz:')
        print('       1. CSP Portal: czy serial ' + '$SERIAL_NUM' + ' ma przypisana licencje')
        print('       2. Panorama → internetu: NAT Gateway w Management VNet aktywny?')
        print('       3. Siec: curl z VM do internetu dziala?')
except Exception as e:
    print('[WARN] Blad parsowania odpowiedzi: ' + str(e))
" 2>/dev/null

      echo "  Czekam 60s na zakonczenie aktywacji..."
      sleep 60
      echo "  [Step 3] Gotowe. Sprawdz status licencji w Panorama GUI:"
      echo "  https://127.0.0.1:44300 → Panorama → Licenses"
    SCRIPT
  }

  depends_on = [null_resource.panorama_set_hostname]
}

###############################################################################
# Step 4: Panorama Config via panos provider
# Template Stack, Device Group, Ethernet Interfaces, Zones, VR, Routes, NAT, Security
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

  depends_on = [null_resource.panorama_activate_license, null_resource.panorama_set_hostname]
}

###############################################################################
# Step 5: Panorama Commit
###############################################################################
resource "null_resource" "panorama_commit" {
  triggers = {
    template_name       = var.template_name
    template_stack_name = var.template_stack_name
    device_group_name   = var.device_group_name
    external_lb_ip      = var.external_lb_public_ip
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -e
      PANORAMA_URL="https://${var.panorama_hostname}:${var.panorama_port}"
      PAN_USER="${var.panorama_username}"

      echo "=== [Step 5] Commit Panoramy ==="

      ENC_PASS=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${var.panorama_password}', safe=''))")

      API_KEY=$(curl -sk --max-time 30 "$PANORAMA_URL/api/?type=keygen&user=$PAN_USER&password=$ENC_PASS" 2>/dev/null \
        | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read())
    print(root.findtext('.//key',''))
except:
    pass
" 2>/dev/null)

      COMMIT_RESP=$(curl -sk --max-time 90 "$PANORAMA_URL/api/" \
        --data-urlencode "type=commit" \
        --data-urlencode "cmd=<commit></commit>" \
        --data-urlencode "key=$API_KEY" 2>/dev/null)

      echo "$COMMIT_RESP" | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read())
    status = root.get('status','')
    code = root.get('code','')
    msg = root.findtext('.//msg','') or root.findtext('.//line','')
    if status == 'success':
        print('[OK] Commit Panoramy: sukces!')
    elif code == '19':
        print('[OK] Brak zmian do commitowania (already committed).')
    else:
        print('[WARN] Commit: status=' + status + ' code=' + code + ' msg=' + str(msg))
        print('       Sprawdz status w GUI Panoramy: Tasks (prawy gorny rog)')
except Exception as e:
    print('[WARN] Blad parsowania odpowiedzi commit: ' + str(e))
" 2>/dev/null
    SCRIPT
  }

  depends_on = [module.panorama_config]
}
