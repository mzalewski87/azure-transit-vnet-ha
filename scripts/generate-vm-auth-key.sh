#!/usr/bin/env bash
###############################################################################
# generate-vm-auth-key.sh
#
# Generuje Device Registration Auth Key przez Panorama XML API.
# Klucz jest wymagany przez VM-Series do automatycznej rejestracji w Panoramie.
#
# WYMAGANIA:
#   1. Panorama MUSI być w pełni uruchomiona i LICENCJONOWANA
#      (serial number + aktywna licencja Panorama)
#   2. Aktywny Bastion tunnel w osobnym terminalu:
#
#       PANORAMA_ID=$(terraform output -raw panorama_vm_id)
#       az network bastion tunnel \
#         --name bastion-spoke2 \
#         --resource-group rg-spoke2-dc \
#         --target-resource-id "$PANORAMA_ID" \
#         --resource-port 443 --port 44300
#
# UŻYCIE:
#   ./scripts/generate-vm-auth-key.sh
#   ./scripts/generate-vm-auth-key.sh --password "TwojeHaslo123!"
#   PANORAMA_PASSWORD="TwojeHaslo123!" ./scripts/generate-vm-auth-key.sh
#
# OUTPUT:
#   Linia gotowa do wklejenia do terraform.tfvars:
#     panorama_vm_auth_key = "2:BKLVoIq7..."
#
# UWAGA: Ten skrypt próbuje kilku formatów XML API (różne wersje Panoramy).
#   Jeśli wszystkie zawiodą, wygeneruj klucz ręcznie w Panorama GUI:
#     Panorama → Devices → VM Auth Key → Generate
###############################################################################

set -uo pipefail

PANORAMA_URL="https://127.0.0.1:44300"
PANORAMA_USER="panadmin"
KEY_LIFETIME_HOURS=1  # 1 godzina – wystarczy na czas deploy

# ── Parsuj argumenty ─────────────────────────────────────────────────────────
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

# ── Pobierz hasło interaktywnie ───────────────────────────────────────────────
if [ -z "$PANORAMA_PASS" ]; then
  echo "Hasło Panoramy = admin_password z terraform.tfvars"
  read -rs -p "Podaj hasło Panoramy: " PANORAMA_PASS
  echo
fi

echo "→ Sprawdzam połączenie z Panoramą ($PANORAMA_URL)..."

if ! curl -sk --max-time 5 "${PANORAMA_URL}/" >/dev/null 2>&1; then
  echo ""
  echo "❌ BŁĄD: Nie można połączyć się z $PANORAMA_URL"
  echo ""
  echo "Upewnij się że Bastion tunnel jest aktywny w osobnym terminalu:"
  echo "  PANORAMA_ID=\$(terraform output -raw panorama_vm_id)"
  echo "  az network bastion tunnel \\"
  echo "    --name bastion-spoke2 --resource-group rg-spoke2-dc \\"
  echo "    --target-resource-id \"\$PANORAMA_ID\" \\"
  echo "    --resource-port 443 --port 44300"
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

echo "→ API key pobrany. Próbuję wygenerować VM Auth Key..."
echo "  (Ważność: ${KEY_LIFETIME_HOURS}h)"
echo ""

# ── Funkcja wywołania API ─────────────────────────────────────────────────────
call_api() {
  local cmd="$1"
  curl -sk "${PANORAMA_URL}/api/" \
    --data-urlencode "type=op" \
    --data-urlencode "cmd=${cmd}" \
    --data-urlencode "key=${API_KEY}"
}

# ── Próba 1: Format PAN-OS 10.2+ (najpopularniejszy) ─────────────────────────
echo "  [Próba 1] <request><bootstrap-vm-auth-key><generate>..."
CMD1="<request><bootstrap-vm-auth-key><generate><lifetime>${KEY_LIFETIME_HOURS}</lifetime></generate></bootstrap-vm-auth-key></request>"
R1=$(call_api "$CMD1")
echo "  Raw: $R1"
KEY=$(echo "$R1" | grep -oE '<bootstrap-vm-auth-key>[^<]+' | sed 's/<bootstrap-vm-auth-key>//' || true)
[ -n "$KEY" ] && VM_AUTH_KEY="$KEY"

# ── Próba 2: Format przez <batch><license> (starsze wersje) ──────────────────
if [ -z "${VM_AUTH_KEY:-}" ]; then
  echo ""
  echo "  [Próba 2] <request><batch><license><generate-vm-auth-key>..."
  CMD2="<request><batch><license><generate-vm-auth-key><lifetime>${KEY_LIFETIME_HOURS}</lifetime></generate-vm-auth-key></license></batch></request>"
  R2=$(call_api "$CMD2")
  echo "  Raw: $R2"
  KEY=$(echo "$R2" | grep -oE '<vm-auth-key>[^<]+' | sed 's/<vm-auth-key>//' || true)
  [ -n "$KEY" ] && VM_AUTH_KEY="$KEY"
  KEY=$(echo "$R2" | grep -oE '<bootstrap-vm-auth-key>[^<]+' | sed 's/<bootstrap-vm-auth-key>//' || true)
  [ -n "$KEY" ] && VM_AUTH_KEY="$KEY"
fi

# ── Próba 3: Format przez <request><authkey> (alternatywny) ──────────────────
if [ -z "${VM_AUTH_KEY:-}" ]; then
  echo ""
  echo "  [Próba 3] <request><authkey><generate>..."
  CMD3="<request><authkey><generate><type>vm-auth-key</type><lifetime>${KEY_LIFETIME_HOURS}</lifetime></generate></authkey></request>"
  R3=$(call_api "$CMD3")
  echo "  Raw: $R3"
  KEY=$(echo "$R3" | grep -oE '<vm-auth-key>[^<]+|<authkey>[^<]+|<bootstrap-vm-auth-key>[^<]+' | sed 's/<[^>]*>//' || true)
  [ -n "$KEY" ] && VM_AUTH_KEY="$KEY"
fi

# ── Próba 4: Bez <generate> zagnieżdżenia ────────────────────────────────────
if [ -z "${VM_AUTH_KEY:-}" ]; then
  echo ""
  echo "  [Próba 4] <request><vm-auth-key><generate>..."
  CMD4="<request><vm-auth-key><generate><lifetime>${KEY_LIFETIME_HOURS}</lifetime></generate></vm-auth-key></request>"
  R4=$(call_api "$CMD4")
  echo "  Raw: $R4"
  KEY=$(echo "$R4" | grep -oE '<vm-auth-key>[^<]+|<bootstrap-vm-auth-key>[^<]+' | sed 's/<[^>]*>//' || true)
  [ -n "$KEY" ] && VM_AUTH_KEY="$KEY"
fi

# ── Wynik ─────────────────────────────────────────────────────────────────────
echo ""
if [ -z "${VM_AUTH_KEY:-}" ]; then
  echo "❌ WSZYSTKIE FORMATY API ZAWIODŁY."
  echo ""
  echo "Sprawdź:"
  echo "  1. Czy Panorama ma aktywną licencję (serial number + aktywacja)?"
  echo "  2. Jaka wersja PAN-OS jest zainstalowana na Panoramie?"
  echo "     (SSH → show system info | match sw-version)"
  echo "  3. Zaloguj się do Panorama GUI i sprawdź:"
  echo "     Panorama → Devices → VM Auth Key → Generate"
  echo ""
  echo "Po ręcznym wygenerowaniu klucza wklej go do terraform.tfvars:"
  echo "  panorama_vm_auth_key = \"2:XXXXXXXX...\""
  exit 1
fi

echo "✅ VM Auth Key wygenerowany pomyślnie!"
echo ""
echo "┌─────────────────────────────────────────────────────────────────────────┐"
echo "│  Skopiuj do terraform.tfvars (zastąp panorama_vm_auth_key):             │"
echo "├─────────────────────────────────────────────────────────────────────────┤"
printf "│  panorama_vm_auth_key = \"%-46s  │\n" "${VM_AUTH_KEY}\""
echo "└─────────────────────────────────────────────────────────────────────────┘"
echo ""
echo "Następne kroki:"
echo "  1. Wklej powyższą wartość do terraform.tfvars"
echo "  2. terraform apply -target=module.bootstrap"
echo "  3. terraform apply -target=module.loadbalancer -target=module.firewall \\"
echo "       -target=module.routing -target=module.frontdoor -target=module.spoke1_app"
