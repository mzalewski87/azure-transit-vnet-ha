#!/usr/bin/env bash
###############################################################################
# register-fw-panorama.sh — Phase 2b: Rejestracja FW na Panoramie
#
# Automatycznie:
#   1. Otwiera Bastion tunnele do FW1, FW2 i Panoramy
#   2. Odczytuje numery seryjne FW z XML API
#   3. Ustawia auth-key na FW (request authkey set)
#   4. Dodaje seriale do Panoramy (mgt-config, device-group, template-stack)
#   5. Commit na Panoramie
#
# Użycie:
#   bash scripts/register-fw-panorama.sh
#
# Wymagania:
#   - Phase 1b zakończona (FW1 + FW2 uruchomione, licencje aktywne)
#   - Phase 2a zakończona (Panorama skonfigurowana, vm-auth-key wygenerowany)
#   - az CLI zalogowany
#
# Komendy XML API (potwierdzone debug cli on na Panoramie):
#   set mgt-config devices SERIAL →
#     type=config&action=set&xpath=/config/mgt-config/devices&element=<entry name='SERIAL'/>
#   set device-group DG devices SERIAL →
#     type=config&action=set&xpath=.../device-group/entry[@name='DG']/devices&element=<entry name='SERIAL'/>
#   set template-stack TS devices SERIAL →
#     type=config&action=set&xpath=.../template-stack/entry[@name='TS']/devices&element=<entry name='SERIAL'/>
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Ports for Bastion tunnels
PANORAMA_PORT=44300
FW1_PORT=44301
FW2_PORT=44302

# Panorama config names (from terraform.tfvars defaults)
DEVICE_GROUP="${DEVICE_GROUP:-Transit-VNet-DG}"
TEMPLATE_STACK="${TEMPLATE_STACK:-Transit-VNet-Stack}"

# Credentials
PAN_USER="${PAN_USER:-panadmin}"

TUNNEL_PIDS=()

cleanup() {
  echo ""
  echo "[*] Zamykanie Bastion tunneli..."
  for pid in "${TUNNEL_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

get_api_key() {
  local url="$1" user="$2" pass="$3"
  local enc_pass
  enc_pass=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$pass', safe=''))")
  curl -sk --max-time 30 \
    "$url/api/?type=keygen&user=$user&password=$enc_pass" 2>/dev/null \
    | python3 -c "
import sys, xml.etree.ElementTree as ET
root = ET.fromstring(sys.stdin.read())
if root.get('status') != 'success':
    print('ERROR:' + (root.findtext('.//msg','login failed')), file=sys.stderr); sys.exit(1)
print(root.findtext('.//key',''))
" 2>&1
}

get_serial() {
  local url="$1" api_key="$2"
  curl -sk --max-time 30 \
    "$url/api/?type=op&cmd=<show><system><info></info></system></show>&key=$api_key" 2>/dev/null \
    | python3 -c "
import sys, xml.etree.ElementTree as ET
root = ET.fromstring(sys.stdin.read())
serial = root.findtext('.//serial', 'unknown')
print(serial)
" 2>/dev/null
}

start_tunnel() {
  local name="$1" vm_id="$2" local_port="$3"
  echo "  Tunnel $name (port $local_port)..."
  az network bastion tunnel \
    --name bastion-management \
    --resource-group rg-transit-hub \
    --target-resource-id "$vm_id" \
    --resource-port 443 \
    --port "$local_port" &>/dev/null &
  TUNNEL_PIDS+=($!)
}

wait_for_tunnel() {
  local port="$1" name="$2"
  for i in $(seq 1 12); do
    if curl -sk --max-time 3 -o /dev/null "https://127.0.0.1:$port" 2>/dev/null; then
      return 0
    fi
    sleep 5
  done
  echo "[BLAD] Tunnel $name (port $port) nie odpowiada."
  return 1
}

echo "============================================================"
echo "  Phase 2b: Rejestracja FW na Panoramie"
echo "============================================================"
echo ""

# Get password
if [ -z "${PAN_PASS:-}" ]; then
  echo -n "Haslo administratora (panadmin): "
  read -rs PAN_PASS
  echo
fi

# Get VM IDs from Terraform output
echo "[1/6] Pobieranie VM IDs z Terraform output..."
cd "$ROOT_DIR"
PANORAMA_ID=$(terraform output -raw panorama_vm_id 2>/dev/null)
FW1_ID=$(terraform output -raw fw1_vm_id 2>/dev/null)
FW2_ID=$(terraform output -raw fw2_vm_id 2>/dev/null)
echo "       Panorama: $PANORAMA_ID"
echo "       FW1:      $FW1_ID"
echo "       FW2:      $FW2_ID"

# Read vm-auth-key (will auto-generate after tunnels are up if missing)
VM_AUTH_KEY=""
if [ -f "$ROOT_DIR/panorama_vm_auth_key.txt" ]; then
  VM_AUTH_KEY=$(cat "$ROOT_DIR/panorama_vm_auth_key.txt" | tr -d '[:space:]')
  echo "       Auth key: ${VM_AUTH_KEY:0:20}..."
else
  echo "       Auth key: brak pliku — zostanie wygenerowany w kroku 3.5"
fi

# Start tunnels
echo ""
echo "[2/6] Uruchamianie Bastion tunneli..."
start_tunnel "Panorama" "$PANORAMA_ID" "$PANORAMA_PORT"
start_tunnel "FW1"      "$FW1_ID"      "$FW1_PORT"
start_tunnel "FW2"      "$FW2_ID"      "$FW2_PORT"

echo "  Czekam na tunnele..."
sleep 10
wait_for_tunnel "$PANORAMA_PORT" "Panorama"
wait_for_tunnel "$FW1_PORT" "FW1"
wait_for_tunnel "$FW2_PORT" "FW2"
echo "  Wszystkie tunnele gotowe!"

# Get serials from FWs
echo ""
echo "[3/6] Odczytywanie numerow seryjnych z FW..."
FW1_KEY=$(get_api_key "https://127.0.0.1:$FW1_PORT" "$PAN_USER" "$PAN_PASS")
FW2_KEY=$(get_api_key "https://127.0.0.1:$FW2_PORT" "$PAN_USER" "$PAN_PASS")

FW1_SERIAL=$(get_serial "https://127.0.0.1:$FW1_PORT" "$FW1_KEY")
FW2_SERIAL=$(get_serial "https://127.0.0.1:$FW2_PORT" "$FW2_KEY")

echo "  FW1 serial: $FW1_SERIAL"
echo "  FW2 serial: $FW2_SERIAL"

if [ "$FW1_SERIAL" = "unknown" ] || [ "$FW2_SERIAL" = "unknown" ]; then
  echo "[BLAD] Nie udalo sie odczytac seriala. Sprawdz czy FW licencja jest aktywna."
  exit 1
fi

# Auto-generate auth-key on Panorama if missing
if [ -z "$VM_AUTH_KEY" ]; then
  echo ""
  echo "[3.5/6] Generowanie vm-auth-key na Panoramie..."
  PAN_KEY_TMP=$(get_api_key "https://127.0.0.1:$PANORAMA_PORT" "$PAN_USER" "$PAN_PASS")

  for GEN_TRY in $(seq 1 5); do
    GEN_RESP=$(curl -sk --max-time 60 \
      "https://127.0.0.1:$PANORAMA_PORT/api/?type=op&cmd=<request><authkey><add><name>authkey-auto</name><lifetime>1440</lifetime><count>10</count></add></authkey></request>&key=$PAN_KEY_TMP" \
      2>/dev/null || echo "")

    VM_AUTH_KEY=$(echo "$GEN_RESP" | python3 -c "
import sys, xml.etree.ElementTree as ET, re
try:
    data = sys.stdin.read()
    if not data: print(''); sys.exit(0)
    root = ET.fromstring(data)
    if root.get('status') != 'success':
        msg = root.findtext('.//msg','') or root.findtext('.//line','')
        print('ERROR: ' + str(msg)); sys.exit(0)
    for elem in root.iter():
        if elem.text:
            m = re.search(r'(2:[\w-]{20,})', elem.text)
            if m: print(m.group(1)); sys.exit(0)
    # Try without 2: prefix — some versions return plain key
    for elem in root.iter():
        if elem.text and len(elem.text.strip()) > 20:
            print(elem.text.strip()); sys.exit(0)
    print('ERROR: key not found'); sys.exit(0)
except Exception as e:
    print('ERROR: ' + str(e)); sys.exit(0)
" 2>/dev/null)

    if [ -n "$VM_AUTH_KEY" ] && ! echo "$VM_AUTH_KEY" | grep -q "^ERROR"; then
      echo "  [OK] Auth key: ${VM_AUTH_KEY:0:30}..."
      # Save for future use
      echo "$VM_AUTH_KEY" > "$ROOT_DIR/panorama_vm_auth_key.txt"
      echo "  Zapisano do: panorama_vm_auth_key.txt"
      break
    fi

    echo "  [$GEN_TRY/5] $VM_AUTH_KEY — czekam 15s..."
    VM_AUTH_KEY=""
    sleep 15
  done

  if [ -z "$VM_AUTH_KEY" ]; then
    echo "  [WARN] Nie udalo sie wygenerowac auth-key."
    echo "         Wygeneruj recznie: SSH do Panoramy -> request authkey add name authkey1 lifetime 1440 count 2"
  fi
fi

# Set auth-key on FWs (if available)
if [ -n "$VM_AUTH_KEY" ]; then
  echo ""
  echo "[4/6] Ustawianie auth-key na firewallach..."
  # CLI: request authkey set KEY
  # XML API: type=op, cmd=<request><authkey><set>KEY</set></authkey></request>
  for fw_info in "FW1:$FW1_PORT:$FW1_KEY" "FW2:$FW2_PORT:$FW2_KEY"; do
    IFS=':' read -r fw_name fw_port fw_key <<< "$fw_info"
    echo "  $fw_name: ustawianie auth-key..."
    AUTH_RESP=$(curl -sk --max-time 30 "https://127.0.0.1:$fw_port/api/" \
      --data-urlencode "type=op" \
      --data-urlencode "cmd=<request><authkey><set>$VM_AUTH_KEY</set></authkey></request>" \
      --data-urlencode "key=$fw_key" 2>/dev/null)
    echo "  $fw_name: done"
  done
else
  echo ""
  echo "[4/6] POMINIETO — brak panorama_vm_auth_key.txt"
  echo "       FW moga nie polaczyc sie z Panorama automatycznie."
fi

# Register serials on Panorama
echo ""
echo "[5/6] Rejestracja seriali na Panoramie..."
PAN_KEY=$(get_api_key "https://127.0.0.1:$PANORAMA_PORT" "$PAN_USER" "$PAN_PASS")
PAN_URL="https://127.0.0.1:$PANORAMA_PORT/api/"

for SERIAL in "$FW1_SERIAL" "$FW2_SERIAL"; do
  echo "  Serial: $SERIAL"

  # mgt-config devices
  echo "    -> mgt-config devices..."
  curl -sk --max-time 30 "$PAN_URL" \
    --data-urlencode "type=config" \
    --data-urlencode "action=set" \
    --data-urlencode "xpath=/config/mgt-config/devices" \
    --data-urlencode "element=<entry name='$SERIAL'/>" \
    --data-urlencode "key=$PAN_KEY" > /dev/null

  # device-group devices
  echo "    -> device-group $DEVICE_GROUP..."
  curl -sk --max-time 30 "$PAN_URL" \
    --data-urlencode "type=config" \
    --data-urlencode "action=set" \
    --data-urlencode "xpath=/config/devices/entry[@name='localhost.localdomain']/device-group/entry[@name='$DEVICE_GROUP']/devices" \
    --data-urlencode "element=<entry name='$SERIAL'/>" \
    --data-urlencode "key=$PAN_KEY" > /dev/null

  # template-stack devices
  echo "    -> template-stack $TEMPLATE_STACK..."
  curl -sk --max-time 30 "$PAN_URL" \
    --data-urlencode "type=config" \
    --data-urlencode "action=set" \
    --data-urlencode "xpath=/config/devices/entry[@name='localhost.localdomain']/template-stack/entry[@name='$TEMPLATE_STACK']/devices" \
    --data-urlencode "element=<entry name='$SERIAL'/>" \
    --data-urlencode "key=$PAN_KEY" > /dev/null

  echo "    OK"
done

# Commit on Panorama
echo ""
echo "[6/6] Commit na Panoramie..."
COMMIT_RESP=$(curl -sk --max-time 90 "$PAN_URL" \
  --data-urlencode "type=commit" \
  --data-urlencode "cmd=<commit></commit>" \
  --data-urlencode "key=$PAN_KEY" 2>/dev/null)

echo "$COMMIT_RESP" | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read())
    status = root.get('status','')
    if status == 'success':
        print('  [OK] Commit: sukces!')
    else:
        msg = root.findtext('.//msg','') or root.findtext('.//line','')
        print('  [WARN] Commit: ' + str(msg))
except Exception as e:
    print('  [WARN] ' + str(e))
" 2>/dev/null

echo ""
echo "============================================================"
echo "  Phase 2b ZAKONCZONA"
echo ""
echo "  FW1 ($FW1_SERIAL) i FW2 ($FW2_SERIAL)"
echo "  zarejestrowane na Panoramie w:"
echo "    Device Group:   $DEVICE_GROUP"
echo "    Template Stack: $TEMPLATE_STACK"
echo ""
echo "  Weryfikacja (SSH do Panoramy):"
echo "    show devices connected"
echo ""
echo "  Opcjonalnie — Phase 3 (DC):"
echo "    terraform apply -target=module.app2_dc"
echo "============================================================"
