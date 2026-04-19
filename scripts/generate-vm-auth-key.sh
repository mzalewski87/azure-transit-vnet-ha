#!/usr/bin/env bash
###############################################################################
# generate-vm-auth-key.sh
#
# Generuje Device Registration Auth Key przez Panorama XML API.
# Klucz wymagany przez VM-Series do automatycznej rejestracji w Panoramie.
#
# WAŻNE WARUNKI WSTĘPNE:
#   1. Panorama MUSI mieć aktywną licencję (serial number + auth code).
#      Bez licencji komenda vm-auth-key zwraca "unexpected" – to jest normalny
#      błąd jeśli init-cfg nie zadziałał. Sprawdź licencję przez GUI:
#        Edge → https://127.0.0.1:44300 → Panorama → Licenses
#
#   2. Aktywny Bastion tunnel w osobnym terminalu:
#        PANORAMA_ID=$(terraform output -raw panorama_vm_id)
#        az network bastion tunnel \
#          --name bastion-spoke2 --resource-group rg-spoke2-dc \
#          --target-resource-id "$PANORAMA_ID" \
#          --resource-port 443 --port 44300
#
# UŻYCIE:
#   ./scripts/generate-vm-auth-key.sh
#   ./scripts/generate-vm-auth-key.sh --password "TwojeHaslo123!"
#   PANORAMA_PASSWORD="TwojeHaslo123!" ./scripts/generate-vm-auth-key.sh
#
# OUTPUT:
#   Linia gotowa do wklejenia do terraform.tfvars:
#     panorama_vm_auth_key = "2:BKLVoIq7..."
###############################################################################

set -uo pipefail

PANORAMA_URL="https://127.0.0.1:44300"
PANORAMA_USER="panadmin"
KEY_LIFETIME_HOURS=1

PANORAMA_PASS="${PANORAMA_PASSWORD:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --password|-p) PANORAMA_PASS="$2"; shift 2 ;;
    --user|-u)     PANORAMA_USER="$2"; shift 2 ;;
    --url)         PANORAMA_URL="$2";  shift 2 ;;
    --hours|-h)    KEY_LIFETIME_HOURS="$2"; shift 2 ;;
    *) echo "Nieznana opcja: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$PANORAMA_PASS" ]; then
  echo "Hasło Panoramy = admin_password z terraform.tfvars"
  read -rs -p "Podaj hasło Panoramy: " PANORAMA_PASS
  echo
fi

echo "→ Sprawdzam połączenie z Panoramą ($PANORAMA_URL)..."
if ! curl -sk --max-time 5 "${PANORAMA_URL}/" >/dev/null 2>&1; then
  cat <<EOF

❌ BŁĄD: Nie można połączyć się z $PANORAMA_URL

Upewnij się że Bastion tunnel jest aktywny w osobnym terminalu:
  PANORAMA_ID=\$(terraform output -raw panorama_vm_id)
  az network bastion tunnel \\
    --name bastion-spoke2 --resource-group rg-spoke2-dc \\
    --target-resource-id "\$PANORAMA_ID" \\
    --resource-port 443 --port 44300
EOF
  exit 1
fi

# ── Pobierz API key ───────────────────────────────────────────────────────────
echo "→ Uwierzytelnianie w Panoramie..."
KEYGEN_RESPONSE=$(curl -sk "${PANORAMA_URL}/api/" \
  -d "type=keygen" \
  --data-urlencode "user=${PANORAMA_USER}" \
  --data-urlencode "password=${PANORAMA_PASS}")

API_KEY=$(echo "$KEYGEN_RESPONSE" | grep -oE '<key>[^<]+' | sed 's/<key>//' || true)

if [ -z "$API_KEY" ]; then
  echo ""
  echo "❌ BŁĄD: Nie można pobrać API key z Panoramy."
  echo "Sprawdź nazwę użytkownika i hasło."
  echo "Odpowiedź: $KEYGEN_RESPONSE"
  exit 1
fi

call_api() {
  curl -sk "${PANORAMA_URL}/api/" \
    --data-urlencode "type=op" \
    --data-urlencode "cmd=$1" \
    --data-urlencode "key=${API_KEY}"
}

# ── Diagnostyka: wersja PAN-OS i licencja ─────────────────────────────────────
echo "→ Pobieram informacje o Panoramie..."
SYS_INFO=$(call_api "<show><system><info></info></system></show>")
SW_VERSION=$(echo "$SYS_INFO" | grep -oE '<sw-version>[^<]+' | sed 's/<sw-version>//' || echo "nieznana")
HOSTNAME=$(echo "$SYS_INFO" | grep -oE '<hostname>[^<]+' | sed 's/<hostname>//' || echo "nieznana")
SERIAL=$(echo "$SYS_INFO" | grep -oE '<serial>[^<]+' | sed 's/<serial>//' || echo "nieznana")
echo "  PAN-OS: $SW_VERSION | Hostname: $HOSTNAME | Serial: $SERIAL"

# Sprawdź licencję
LICENSE_INFO=$(call_api "<show><license></license></show>")
if echo "$LICENSE_INFO" | grep -qi "Panorama"; then
  echo "  Licencja Panoramy: ✅ aktywna"
else
  cat <<EOF

⚠️  OSTRZEŻENIE: Licencja Panoramy może być NIEAKTYWNA.

Odpowiedź z <show><license>: $LICENSE_INFO

Bez licencji komenda vm-auth-key zwraca błąd "unexpected".
Sprawdź licencję przez GUI (Microsoft Edge):
  https://127.0.0.1:44300 → Panorama → Device → Licenses

Jeśli licencja nie jest aktywna:
  1. Sprawdź czy panorama_serial_number jest ustawiony w terraform.tfvars
  2. Sprawdź czy panorama_auth_code jest poprawny
  3. Aktywuj ręcznie: Panorama → Device → Licenses → Activate → podaj auth code

EOF
fi

echo ""
echo "→ Próbuję wygenerować VM Auth Key (wymagana aktywna licencja Panoramy)..."
echo "  (Ważność: ${KEY_LIFETIME_HOURS}h)"
echo ""

VM_AUTH_KEY=""

# ── Próba 1: Standardowy format PAN-OS 10.x / 11.x ───────────────────────────
echo "  [Próba 1] request > vm-auth-key > generate..."
R1=$(call_api "<request><vm-auth-key><generate><lifetime>${KEY_LIFETIME_HOURS}</lifetime></generate></vm-auth-key></request>")
echo "  Raw: $R1"
KEY=$(echo "$R1" | grep -oP '(?<=<result>)[^<]+|(?<=<vm-auth-key>)[^<]+|(?<=<key>)[^<]+' | head -1 || true)
[ -n "$KEY" ] && VM_AUTH_KEY="$KEY"

# ── Próba 2: Format z zagnieżdżonym bootstrap ─────────────────────────────────
if [ -z "$VM_AUTH_KEY" ]; then
  echo ""
  echo "  [Próba 2] request > bootstrap-vm-auth-key > generate..."
  R2=$(call_api "<request><bootstrap-vm-auth-key><generate><lifetime>${KEY_LIFETIME_HOURS}</lifetime></generate></bootstrap-vm-auth-key></request>")
  echo "  Raw: $R2"
  KEY=$(echo "$R2" | grep -oP '(?<=<result>)[^<]+|(?<=<bootstrap-vm-auth-key>)[^<]+|(?<=<key>)[^<]+' | head -1 || true)
  [ -n "$KEY" ] && VM_AUTH_KEY="$KEY"
fi

# ── Próba 3: Format przez batch > license ─────────────────────────────────────
if [ -z "$VM_AUTH_KEY" ]; then
  echo ""
  echo "  [Próba 3] request > batch > license > generate-vm-auth-key..."
  R3=$(call_api "<request><batch><license><generate-vm-auth-key><lifetime>${KEY_LIFETIME_HOURS}</lifetime></generate-vm-auth-key></license></batch></request>")
  echo "  Raw: $R3"
  KEY=$(echo "$R3" | grep -oP '(?<=<vm-auth-key>)[^<]+|(?<=<key>)[^<]+' | head -1 || true)
  [ -n "$KEY" ] && VM_AUTH_KEY="$KEY"
fi

# ── Próba 4: Pokazanie istniejących kluczy ────────────────────────────────────
if [ -z "$VM_AUTH_KEY" ]; then
  echo ""
  echo "  [Próba 4] Sprawdzam istniejące vm-auth-keys..."
  R4=$(call_api "<show><vm-auth-key><all/></vm-auth-key></show>")
  echo "  Raw: $R4"
  KEY=$(echo "$R4" | grep -oP '(?<=<key>)[^<]+' | head -1 || true)
  [ -n "$KEY" ] && VM_AUTH_KEY="$KEY" && echo "  → Znaleziono istniejący klucz!"
fi

# ── Wynik ─────────────────────────────────────────────────────────────────────
echo ""
if [ -z "$VM_AUTH_KEY" ]; then
  cat <<EOF
❌ WSZYSTKIE FORMATY API ZAWIODŁY.

Najczęstsza przyczyna: Panorama nie ma aktywnej licencji.
Sprawdź PAN-OS version: $SW_VERSION, Serial: $SERIAL

WERYFIKACJA LICENCJI przez SSH:
  az network bastion ssh --name bastion-spoke2 \\
    --resource-group rg-spoke2-dc \\
    --target-ip-address 10.0.0.10 \\
    --auth-type password --username panadmin
  > show system info | match sw-version
  > show license

RĘCZNE GENEROWANIE w Panorama GUI (Microsoft Edge):
  https://127.0.0.1:44300
  → Panorama → Devices → VM Auth Key → Generate → 1 hour
  LUB:
  → Panorama → Setup → Bootstrap → Generate VM Auth Key (nowsze wersje)

Po ręcznym wygenerowaniu klucza wklej do terraform.tfvars:
  panorama_vm_auth_key = "2:XXXXXXXX..."

UWAGA: Jeśli GUI też nie pokazuje opcji VM Auth Key, Panorama NIE MA licencji.
  Sprawdź: terraform.tfvars → panorama_serial_number i panorama_auth_code
EOF
  exit 1
fi

echo "✅ VM Auth Key wygenerowany pomyślnie!"
echo ""
echo "┌─────────────────────────────────────────────────────────────────────────┐"
echo "│  Skopiuj do terraform.tfvars (zastąp panorama_vm_auth_key):             │"
echo "├─────────────────────────────────────────────────────────────────────────┤"
printf "│  panorama_vm_auth_key = \"%-47s │\n" "${VM_AUTH_KEY}\""
echo "└─────────────────────────────────────────────────────────────────────────┘"
echo ""
echo "Następne kroki:"
echo "  1. Wklej powyższą wartość do terraform.tfvars"
echo "  2. terraform apply -target=module.bootstrap"
echo "  3. terraform apply -target=module.loadbalancer -target=module.firewall \\"
echo "       -target=module.routing -target=module.frontdoor -target=module.spoke1_app"
