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
#   3. terraform.tfvars uzupełniony (hasło, serial_number, CIDRy)
#
# SEKWENCJA:
#   1. Wait for Panorama API (max 20 min)
#   2. Set hostname via XML API + commit
#   3. Set serial number via XML API (config mode) + commit + license fetch
#   4. Generate vm-auth-key via XML API (automatycznie!)
#   5. panos provider: Template Stack, DG, interfaces, zones, routes, policies
#   6. Final commit
###############################################################################

###############################################################################
# Step 1: Wait for Panorama API
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
          echo "[BLAD] Panorama API nie odpowiada po $MAX_ATTEMPTS probach."
          exit 1
        fi
        echo "  [$ATTEMPTS/$MAX_ATTEMPTS] HTTP $HTTP_CODE – czekam 30s..."
        sleep 30
      done
    SCRIPT
  }
}

###############################################################################
# Step 2: Set hostname via XML API (config mode + commit)
###############################################################################
resource "null_resource" "panorama_set_hostname" {
  triggers = {
    target_hostname = var.panorama_target_hostname
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -e
      PANORAMA_URL="https://${var.panorama_hostname}:${var.panorama_port}"
      PAN_USER="${var.panorama_username}"
      TARGET_HOST="${var.panorama_target_hostname}"

      echo "=== [Step 2] Ustawiam hostname: $TARGET_HOST ==="

      ENC_PASS=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${var.panorama_password}', safe=''))")
      API_KEY=$(curl -sk --max-time 30 \
        "$PANORAMA_URL/api/?type=keygen&user=$PAN_USER&password=$ENC_PASS" 2>/dev/null \
        | python3 -c "
import sys, xml.etree.ElementTree as ET
root = ET.fromstring(sys.stdin.read())
if root.get('status') != 'success':
    print('ERROR: ' + (root.findtext('.//msg','no message')), file=sys.stderr); sys.exit(1)
print(root.findtext('.//key',''))
" 2>&1)

      if echo "$API_KEY" | grep -q "^ERROR:"; then
        echo "[BLAD] API key: $API_KEY"; exit 1
      fi
      echo "  API key: OK"

      curl -sk --max-time 30 "$PANORAMA_URL/api/" \
        --data-urlencode "type=config" \
        --data-urlencode "action=set" \
        --data-urlencode "xpath=/config/devices/entry[@name='localhost.localdomain']/deviceconfig/system" \
        --data-urlencode "element=<hostname>$TARGET_HOST</hostname>" \
        --data-urlencode "key=$API_KEY" > /dev/null

      curl -sk --max-time 60 "$PANORAMA_URL/api/" \
        --data-urlencode "type=commit" \
        --data-urlencode "cmd=<commit></commit>" \
        --data-urlencode "key=$API_KEY" > /dev/null

      echo "  Hostname '$TARGET_HOST' ustawiony + commit OK"
    SCRIPT
  }

  depends_on = [null_resource.panorama_wait_for_api]
}

###############################################################################
# Step 3: Set serial number (OPERATIONAL mode) + commit + license fetch
#
# Serial number na Panoramie ustawia się komendą operational mode:
#   set serial-number 000710041165
#
# XML API equivalent (potwierdzone debug cli on):
#   type=op&cmd=<set><serial-number>SERIAL</serial-number></set>
#
# Sekwencja:
#   1. Set serial via operational mode (type=op)
#   2. Commit
#   3. request license fetch (operational)
###############################################################################
resource "null_resource" "panorama_activate_license" {
  count = var.panorama_serial_number != "" ? 1 : 0

  triggers = {
    serial_number = var.panorama_serial_number
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -e
      PANORAMA_URL="https://${var.panorama_hostname}:${var.panorama_port}"
      PAN_USER="${var.panorama_username}"
      SERIAL_NUM="${var.panorama_serial_number}"

      echo "=== [Step 3] Serial number + aktywacja licencji ==="
      echo "    Serial: $SERIAL_NUM"

      ENC_PASS=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${var.panorama_password}', safe=''))")
      API_KEY=$(curl -sk --max-time 30 \
        "$PANORAMA_URL/api/?type=keygen&user=$PAN_USER&password=$ENC_PASS" 2>/dev/null \
        | python3 -c "
import sys, xml.etree.ElementTree as ET
root = ET.fromstring(sys.stdin.read())
if root.get('status') != 'success':
    print('ERROR: ' + (root.findtext('.//msg','no message')), file=sys.stderr); sys.exit(1)
print(root.findtext('.//key',''))
" 2>&1)

      if echo "$API_KEY" | grep -q "^ERROR:"; then
        echo "[BLAD] API key: $API_KEY"; exit 1
      fi
      echo "  API key: OK"

      # 3a: Set serial number via OPERATIONAL mode
      # CLI: set serial-number 000710041165
      # XML API: type=op, cmd=<set><serial-number>SERIAL</serial-number></set>
      # UWAGA: Po set serial-number Panorama może zrestartować management service.
      #        Dlatego max-time=120 i po nim pętla wait na API.
      echo "  Ustawianie serial number (operational mode)..."
      SET_RESP=$(curl -sk --max-time 120 "$PANORAMA_URL/api/" \
        --data-urlencode "type=op" \
        --data-urlencode "cmd=<set><serial-number>$SERIAL_NUM</serial-number></set>" \
        --data-urlencode "key=$API_KEY" 2>/dev/null || echo "<response status='timeout'/>")

      SET_STATUS=$(echo "$SET_RESP" | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read())
    if root.get('status') == 'success':
        print('OK')
    elif root.get('status') == 'timeout':
        print('TIMEOUT')
    else:
        msg = root.findtext('.//msg','') or root.findtext('.//line','')
        print('ERROR: ' + str(msg))
except Exception as e:
    print('ERROR: ' + str(e))
" 2>/dev/null)

      if echo "$SET_STATUS" | grep -q "^ERROR:"; then
        echo "  [BLAD] Set serial: $SET_STATUS"
        exit 1
      fi
      if [ "$SET_STATUS" = "TIMEOUT" ]; then
        echo "  Set serial: timeout (Panorama restartuje management service — to normalne)"
      else
        echo "  Set serial: OK"
      fi

      # 3a2: Czekaj na API po set serial-number (management service może się restartować)
      echo "  Czekam na Panorama API po zmianie serial number..."
      sleep 15
      for WAIT_I in $(seq 1 20); do
        WAIT_CODE=$(curl -sk --max-time 10 -o /dev/null -w "%%{http_code}" "$PANORAMA_URL/php/login.php" 2>/dev/null || echo "000")
        if [ "$WAIT_CODE" = "200" ] || [ "$WAIT_CODE" = "302" ]; then
          echo "  Panorama API gotowa (HTTP $WAIT_CODE, proba $WAIT_I)"
          break
        fi
        if [ "$WAIT_I" -ge 20 ]; then
          echo "  [WARN] Panorama API nie odpowiada po 20 probach."
        fi
        echo "  [$WAIT_I/20] HTTP $WAIT_CODE — czekam 10s..."
        sleep 10
      done

      # Nowy API key (stary mógł wygasnąć po restarcie)
      API_KEY=$(curl -sk --max-time 30 \
        "$PANORAMA_URL/api/?type=keygen&user=$PAN_USER&password=$ENC_PASS" 2>/dev/null \
        | python3 -c "
import sys, xml.etree.ElementTree as ET
root = ET.fromstring(sys.stdin.read())
print(root.findtext('.//key',''))
" 2>/dev/null)

      # 3b: Commit
      echo "  Commit po ustawieniu serial..."
      curl -sk --max-time 120 "$PANORAMA_URL/api/" \
        --data-urlencode "type=commit" \
        --data-urlencode "cmd=<commit></commit>" \
        --data-urlencode "key=$API_KEY" > /dev/null
      echo "  Commit: OK"

      echo "  Czekam 30s na propagację serial number..."
      sleep 30

      # 3c: License fetch (operational mode, z retry)
      echo "  Pobieranie licencji (request license fetch)..."
      MAX_RETRIES=5
      for i in $(seq 1 $MAX_RETRIES); do
        LIC_RESP=$(curl -sk --max-time 120 "$PANORAMA_URL/api/" \
          --data-urlencode "type=op" \
          --data-urlencode "cmd=<request><license><fetch></fetch></license></request>" \
          --data-urlencode "key=$API_KEY" 2>/dev/null)

        LIC_STATUS=$(echo "$LIC_RESP" | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read())
    status = root.get('status','')
    msg = root.findtext('.//msg','') or root.findtext('.//line','') or 'brak info'
    if status == 'success':
        print('OK')
    else:
        print('RETRY: ' + msg)
except Exception as e:
    print('RETRY: ' + str(e))
" 2>/dev/null)

        if [ "$LIC_STATUS" = "OK" ]; then
          echo "  [OK] Licencja pobrana pomyslnie!"
          break
        fi

        if [ "$i" -lt "$MAX_RETRIES" ]; then
          echo "  [$i/$MAX_RETRIES] $LIC_STATUS – czekam 30s..."
          sleep 30
        else
          echo "  [WARN] License fetch nie powiodl sie po $MAX_RETRIES probach: $LIC_STATUS"
          echo "  Sprawdz: CSP Portal, NAT Gateway, dostep do internetu"
        fi
      done

      echo "  [Step 3] Gotowe."
    SCRIPT
  }

  depends_on = [null_resource.panorama_set_hostname]
}

###############################################################################
# Step 4: Generate vm-auth-key automatically via XML API
#
# Generuje Device Registration Auth Key na Panoramie.
# Klucz jest potrzebny w FW init-cfg do automatycznej rejestracji.
# Licencja Panoramy NIE jest wymagana do wygenerowania klucza.
#
# Output: klucz zapisywany do pliku ../panorama_vm_auth_key.txt
###############################################################################
resource "null_resource" "panorama_generate_vm_auth_key" {
  triggers = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -e
      PANORAMA_URL="https://${var.panorama_hostname}:${var.panorama_port}"
      PAN_USER="${var.panorama_username}"
      LIFETIME="${var.vm_auth_key_lifetime}"

      echo "=== [Step 4] Generowanie vm-auth-key (lifetime: $LIFETIME min) ==="

      ENC_PASS=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${var.panorama_password}', safe=''))")
      API_KEY=$(curl -sk --max-time 30 \
        "$PANORAMA_URL/api/?type=keygen&user=$PAN_USER&password=$ENC_PASS" 2>/dev/null \
        | python3 -c "
import sys, xml.etree.ElementTree as ET
root = ET.fromstring(sys.stdin.read())
if root.get('status') != 'success':
    print('ERROR: ' + (root.findtext('.//msg','no message')), file=sys.stderr); sys.exit(1)
print(root.findtext('.//key',''))
" 2>&1)

      if echo "$API_KEY" | grep -q "^ERROR:"; then
        echo "[BLAD] API key: $API_KEY"; exit 1
      fi

      # Generate key
      KEY_RESP=$(curl -sk --max-time 30 \
        "$PANORAMA_URL/api/?type=op&cmd=<request><authkey><add><name>authkey-auto</name><lifetime>$LIFETIME</lifetime><count>10</count></add></authkey></request>&key=$API_KEY" \
        2>/dev/null)

      VM_AUTH_KEY=$(echo "$KEY_RESP" | python3 -c "
import sys, xml.etree.ElementTree as ET, re
try:
    root = ET.fromstring(sys.stdin.read())
    if root.get('status') != 'success':
        msg = root.findtext('.//msg','') or root.findtext('.//line','')
        print('ERROR: ' + str(msg), file=sys.stderr); sys.exit(1)
    # Search for key pattern in all elements
    for elem in root.iter():
        if elem.text:
            m = re.search(r'(2:[\w-]{20,})', elem.text)
            if m:
                print(m.group(1)); sys.exit(0)
    print('ERROR: key not found in response', file=sys.stderr); sys.exit(1)
except ET.ParseError as e:
    print('ERROR: ' + str(e), file=sys.stderr); sys.exit(1)
" 2>&1)

      if echo "$VM_AUTH_KEY" | grep -q "^ERROR:"; then
        echo "[WARN] Nie udalo sie wygenerowac vm-auth-key: $VM_AUTH_KEY"
        echo "       Wygeneruj recznie: admin@panorama> request authkey add name authkey1 lifetime $LIFETIME count 2"
        exit 0
      fi

      echo ""
      echo "  ========================================"
      echo "  vm-auth-key: $VM_AUTH_KEY"
      echo "  ========================================"
      echo ""

      # Save to .txt (backup)
      echo "$VM_AUTH_KEY" > ../panorama_vm_auth_key.txt
      echo "  Zapisano do: ../panorama_vm_auth_key.txt"

      # Auto-inject into root terraform — .auto.tfvars is auto-loaded!
      cat > ../panorama_vm_auth_key.auto.tfvars <<EOF
# Auto-generated by Phase 2a ($(date -u +%Y-%m-%dT%H:%M:%SZ))
# vm-auth-key wygenerowany na Panoramie — używany w FW bootstrap init-cfg
panorama_vm_auth_key = "$VM_AUTH_KEY"
EOF
      echo "  Zapisano do: ../panorama_vm_auth_key.auto.tfvars (auto-loaded by Terraform)"
      echo ""
      echo "  Phase 1b automatycznie pobierze vm-auth-key."
      echo "  Uruchom w glownym katalogu:"
      echo "    cd .."
      echo "    terraform apply -target=module.bootstrap \\"
      echo "      -target=module.loadbalancer -target=module.firewall \\"
      echo "      -target=module.routing -target=module.frontdoor -target=module.app1_app"
    SCRIPT
  }

  # Step 4 MUSI czekać na Step 3 (serial number + license activation).
  # Po set serial-number Panorama restartuje management service — Step 4 musi
  # uruchomić się PO tym, jak API wróci do działania (Step 3 na to czeka).
  depends_on = [null_resource.panorama_activate_license]
}

###############################################################################
# Step 5: Panorama Config via panos provider
# Template Stack, Device Group, Interfaces, Zones, VR, Routes, NAT, Security
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
# Step 6: Final Panorama Commit
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

      echo "=== [Step 6] Final Commit Panoramy ==="

      ENC_PASS=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${var.panorama_password}', safe=''))")
      API_KEY=$(curl -sk --max-time 30 "$PANORAMA_URL/api/?type=keygen&user=$PAN_USER&password=$ENC_PASS" 2>/dev/null \
        | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read())
    print(root.findtext('.//key',''))
except: pass
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
    if status == 'success':
        print('[OK] Commit: sukces!')
    elif code == '19':
        print('[OK] Brak zmian do commitowania.')
    else:
        msg = root.findtext('.//msg','') or root.findtext('.//line','')
        print('[WARN] Commit: status=' + status + ' msg=' + str(msg))
except Exception as e:
    print('[WARN] Blad: ' + str(e))
" 2>/dev/null
    SCRIPT
  }

  depends_on = [module.panorama_config]
}
