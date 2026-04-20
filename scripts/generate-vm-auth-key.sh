#!/usr/bin/env bash
###############################################################################
# generate-vm-auth-key.sh
# Generuje Device Registration Auth Key z Panoramy przez XML API
#
# Wymagania:
#   - Panorama uruchomiona (licencja NIE jest wymagana do wygenerowania klucza)
#   - Dostep do Panoramy przez Bastion (tunnel lub IpConnect)
#
# Uzycie:
#   ./scripts/generate-vm-auth-key.sh [--panorama-ip <IP>] [--username <user>]
#
# Wynik: klucz wyswietlany na ekranie i zapisywany do panorama_vm_auth_key.txt
#
# ALTERNATYWA – recznie przez Bastion SSH do Panoramy:
#
#   Metoda A (wymaga ip_connect_enabled=true):
#     az network bastion ssh \
#       --name bastion-management \
#       --resource-group rg-transit-hub \
#       --target-ip-address 10.255.0.4 \
#       --auth-type password --username panadmin
#
#   Metoda B (zawsze dziala, pobiera VM resource ID):
#     PANORAMA_ID=$(terraform output -raw panorama_vm_id)
#     az network bastion ssh \
#       --name bastion-management \
#       --resource-group rg-transit-hub \
#       --target-resource-id "$PANORAMA_ID" \
#       --auth-type password --username panadmin
#
#   Po zalogowaniu do Panoramy:
#     admin@panorama> request authkey add name authkey1 lifetime 60 count 2
#     (lifetime w minutach; count = liczba FW ktore moga uzyc tego klucza)
###############################################################################

set -euo pipefail

PANORAMA_IP="${PANORAMA_IP:-10.255.0.4}"
PANORAMA_USER="${PANORAMA_USER:-panadmin}"
PANORAMA_PORT="${PANORAMA_PORT:-443}"
LIFETIME="${LIFETIME:-60}"

usage() {
  echo "Usage: $0 [--panorama-ip <IP>] [--username <user>] [--password <pass>] [--lifetime <minutes>]"
  echo ""
  echo "Environment variables (alternative to flags):"
  echo "  PANORAMA_IP       Panorama private IP (default: 10.255.0.4)"
  echo "  PANORAMA_USER     Username (default: panadmin)"
  echo "  PANORAMA_PASSWORD Password"
  echo "  LIFETIME          Key validity in minutes (default: 60 = 1h)"
  echo ""
  echo "Requires: curl, python3"
  exit 1
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --panorama-ip)   PANORAMA_IP="$2"; shift 2;;
    --username)      PANORAMA_USER="$2"; shift 2;;
    --password)      PANORAMA_PASSWORD="$2"; shift 2;;
    --lifetime)      LIFETIME="$2"; shift 2;;    # w minutach
    -h|--help)       usage;;
    *)               echo "Unknown arg: $1"; usage;;
  esac
done

# Get password if not set
if [[ -z "${PANORAMA_PASSWORD:-}" ]]; then
  echo -n "Panorama password for ${PANORAMA_USER}@${PANORAMA_IP}: "
  read -rs PANORAMA_PASSWORD
  echo
fi

BASE_URL="https://${PANORAMA_IP}:${PANORAMA_PORT}/api"

echo ""
echo "=== Panorama Device Registration Auth Key Generator ==="
echo "  Panorama:  ${PANORAMA_IP}:${PANORAMA_PORT}"
echo "  User:      ${PANORAMA_USER}"
echo "  Lifetime:  ${LIFETIME} min"
echo ""

###############################################################################
# STEP 1: Login – get API key
###############################################################################
echo "[1/3] Logging in to Panorama..."

LOGIN_RESPONSE=$(curl -sk --max-time 30 \
  -X GET \
  "${BASE_URL}/?type=keygen&user=${PANORAMA_USER}&password=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote('${PANORAMA_PASSWORD}', safe=''))")" \
  2>/dev/null)

if [[ -z "$LOGIN_RESPONSE" ]]; then
  echo "ERROR: No response from Panorama. Check IP/port and network connectivity."
  echo "       Make sure Bastion tunnel is running if accessing through Bastion."
  echo ""
  echo "  Start tunnel:"
  echo "  PANORAMA_ID=\$(terraform output -raw panorama_vm_id)"
  echo "  az network bastion tunnel --name bastion-management \\"
  echo "    --resource-group rg-transit-hub \\"
  echo "    --target-resource-id \"\$PANORAMA_ID\" \\"
  echo "    --resource-port 443 --port 44300"
  echo ""
  echo "  Then run: PANORAMA_IP=127.0.0.1 PANORAMA_PORT=44300 $0"
  exit 1
fi

# Extract API key using python3 (portable – works on macOS and Linux)
API_KEY=$(echo "$LOGIN_RESPONSE" | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read())
    status = root.get('status', '')
    if status != 'success':
        msg = root.findtext('.//msg', '') or root.findtext('.//line', '')
        print(f'ERROR: Login failed: {msg}', file=sys.stderr)
        sys.exit(1)
    key = root.findtext('.//key', '')
    if not key:
        print('ERROR: No key in response', file=sys.stderr)
        sys.exit(1)
    print(key)
except ET.ParseError as e:
    print(f'ERROR: XML parse error: {e}', file=sys.stderr)
    sys.exit(1)
" 2>&1)

if echo "$API_KEY" | grep -q "^ERROR:"; then
  echo "FAILED: $API_KEY"
  echo ""
  echo "Response was:"
  echo "$LOGIN_RESPONSE"
  exit 1
fi

echo "      Login: OK"

###############################################################################
# STEP 2: Show system info (informacyjnie – nie blokuje generowania klucza)
###############################################################################
echo "[2/3] Checking Panorama system info..."

INFO_RESPONSE=$(curl -sk --max-time 30 \
  -X GET \
  "${BASE_URL}/?type=op&cmd=<show><system><info></info></system></show>&key=${API_KEY}" \
  2>/dev/null)

SYSINFO=$(echo "$INFO_RESPONSE" | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read())
    serial = root.findtext('.//serial', 'unknown')
    sw_version = root.findtext('.//sw-version', 'unknown')
    model = root.findtext('.//model', 'unknown')
    print(f'{serial}|{sw_version}|{model}')
except:
    print('unknown|unknown|unknown')
" 2>/dev/null)

SERIAL_NUM=$(echo "$SYSINFO" | cut -d'|' -f1)
SW_VER=$(echo "$SYSINFO" | cut -d'|' -f2)
MODEL=$(echo "$SYSINFO" | cut -d'|' -f3)

echo "      Model:   ${MODEL}"
echo "      Version: ${SW_VER}"
echo "      Serial:  ${SERIAL_NUM}"
echo "      (licencja nie jest wymagana do wygenerowania klucza)"

###############################################################################
# STEP 3: Generate Device Registration Auth Key
# Komenda CLI: request authkey add name authkey1 lifetime 60 count 2
###############################################################################
echo "[3/3] Generating Device Registration Auth Key (lifetime: ${LIFETIME} min)..."

KEY_RESPONSE=$(curl -sk --max-time 30 \
  -X GET \
  "${BASE_URL}/?type=op&cmd=<request><authkey><add><name>authkey1</name><lifetime>${LIFETIME}</lifetime><count>10</count></add></authkey></request>&key=${API_KEY}" \
  2>/dev/null)

VM_AUTH_KEY=$(echo "$KEY_RESPONSE" | python3 -c "
import sys, xml.etree.ElementTree as ET, re
try:
    root = ET.fromstring(sys.stdin.read())
    status = root.get('status', '')
    if status != 'success':
        msg = root.findtext('.//msg', '') or root.findtext('.//line', '')
        print(f'ERROR: {msg}', file=sys.stderr)
        sys.exit(1)

    # Try direct key element first
    key_elem = root.find('.//key')
    if key_elem is not None and key_elem.text:
        print(key_elem.text.strip())
        sys.exit(0)

    # Try any element text matching key pattern
    for elem in root.iter():
        if elem.text:
            m = re.search(r'([\w:]+\w{32,})', elem.text)
            if m:
                print(m.group(1))
                sys.exit(0)

    # Print raw for manual extraction
    print('MANUAL_EXTRACT_NEEDED', file=sys.stderr)
    sys.exit(1)
except ET.ParseError as e:
    print(f'ERROR: XML parse error: {e}', file=sys.stderr)
    sys.exit(1)
" 2>&1)

if echo "$VM_AUTH_KEY" | grep -q "^ERROR:"; then
  echo ""
  echo "FAILED to generate auth key: $VM_AUTH_KEY"
  echo ""
  echo "Raw response:"
  echo "$KEY_RESPONSE"
  echo ""
  echo "ALTERNATIVE: Use SSH CLI directly:"
  echo "  admin@panorama> request authkey add name authkey1 lifetime ${LIFETIME} count 2"
  exit 1
fi

if echo "$VM_AUTH_KEY" | grep -q "MANUAL_EXTRACT_NEEDED"; then
  echo ""
  echo "Key generated but automatic extraction failed. Raw response:"
  echo "$KEY_RESPONSE"
  echo ""
  echo "Copy the key manually and add to ROOT terraform.tfvars:"
  echo "  panorama_vm_auth_key = \"<key>\""
  exit 1
fi

###############################################################################
# SUCCESS
###############################################################################
echo ""
echo "======================================================================"
echo "  Device Registration Auth Key generated successfully!"
echo "======================================================================"
echo ""
echo "  Key: ${VM_AUTH_KEY}"
echo ""

# Save to file
OUTPUT_FILE="panorama_vm_auth_key.txt"
echo "$VM_AUTH_KEY" > "$OUTPUT_FILE"
echo "  Saved to: ${OUTPUT_FILE}"
echo ""

echo "  Add to ROOT terraform.tfvars (w glownym katalogu projektu!):"
echo "  panorama_vm_auth_key = \"${VM_AUTH_KEY}\""
echo ""
echo "  Then re-run bootstrap module to update FW init-cfg:"
echo "  terraform apply -target=module.bootstrap"
echo "  terraform apply -target=module.firewall"
echo ""
echo "  Expires in: ${LIFETIME} minutes"
echo "======================================================================"
