#!/usr/bin/env bash
###############################################################################
# generate-vm-auth-key.sh
#
# Generuje Device Registration Auth Key (vm-auth-key) przez Panorama API.
# Eliminuje konieczność ręcznego logowania do Panorama GUI.
#
# WYMAGANIA:
#   - Aktywny Bastion tunnel do Panoramy (127.0.0.1:44300):
#       az network bastion tunnel --name bastion-spoke2 \
#         --resource-group rg-spoke2-dc \
#         --target-resource-id "$(terraform output -raw panorama_vm_id)" \
#         --resource-port 443 --port 44300
#
# UŻYCIE:
#   ./scripts/generate-vm-auth-key.sh
#   ./scripts/generate-vm-auth-key.sh --password "TwojeHaslo123!"
#   PANORAMA_PASSWORD="TwojeHaslo123!" ./scripts/generate-vm-auth-key.sh
#
# OUTPUT:
#   Linia gotowa do wklejenia do terraform.tfvars:
#     panorama_vm_auth_key = "2:BKLVoIq7Ty2GZqT1JcNI8a..."
###############################################################################

set -euo pipefail

PANORAMA_URL="https://127.0.0.1:44300"
PANORAMA_USER="panadmin"
KEY_LIFETIME_HOURS=8760  # 1 rok

# ── Parsuj argumenty ─────────────────────────────────────────────────────────
PANORAMA_PASS="${PANORAMA_PASSWORD:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --password|-p)
      PANORAMA_PASS="$2"; shift 2 ;;
    --user|-u)
      PANORAMA_USER="$2"; shift 2 ;;
    --url)
      PANORAMA_URL="$2"; shift 2 ;;
    *)
      echo "Nieznana opcja: $1" >&2; exit 1 ;;
  esac
done

# ── Pobierz hasło interaktywnie jeśli nie podane ─────────────────────────────
if [ -z "$PANORAMA_PASS" ]; then
  echo "Hasło Panoramy = admin_password z terraform.tfvars"
  read -rs -p "Podaj hasło Panoramy: " PANORAMA_PASS
  echo
fi

echo "→ Sprawdzam połączenie z Panoramą ($PANORAMA_URL)..."

# ── Sprawdź czy Bastion tunnel działa ────────────────────────────────────────
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

API_KEY=$(echo "$KEYGEN_RESPONSE" | grep -oE '<key>[^<]+' | sed 's/<key>//')

if [ -z "$API_KEY" ]; then
  echo ""
  echo "❌ BŁĄD: Nie można pobrać API key z Panoramy."
  echo "Sprawdź nazwę użytkownika i hasło."
  echo "Odpowiedź: $KEYGEN_RESPONSE"
  exit 1
fi

echo "→ Generowanie VM Auth Key (ważność: ${KEY_LIFETIME_HOURS}h)..."

# ── Generuj VM Auth Key przez Panorama API ────────────────────────────────────
AUTH_KEY_RESPONSE=$(curl -sk "${PANORAMA_URL}/api/" \
  --data-urlencode "type=op" \
  --data-urlencode "cmd=<request><bootstrap-vm-auth-key><generate><lifetime>${KEY_LIFETIME_HOURS}</lifetime></generate></bootstrap-vm-auth-key></request>" \
  --data-urlencode "key=${API_KEY}")

VM_AUTH_KEY=$(echo "$AUTH_KEY_RESPONSE" | grep -oE '<vm-auth-key>[^<]+' | sed 's/<vm-auth-key>//')

if [ -z "$VM_AUTH_KEY" ]; then
  echo ""
  echo "❌ BŁĄD: Nie można wygenerować VM Auth Key."
  echo "Możliwa przyczyna: Panorama nie ma licencji lub nie jest w pełni uruchomiona."
  echo "Odpowiedź API: $AUTH_KEY_RESPONSE"
  exit 1
fi

# ── Wynik ─────────────────────────────────────────────────────────────────────
echo ""
echo "✅ VM Auth Key wygenerowany pomyślnie!"
echo ""
echo "┌─────────────────────────────────────────────────────────────────────┐"
echo "│  Skopiuj do terraform.tfvars (zastąp panorama_vm_auth_key):         │"
echo "├─────────────────────────────────────────────────────────────────────┤"
echo "│  panorama_vm_auth_key = \"${VM_AUTH_KEY}\"  │"
echo "└─────────────────────────────────────────────────────────────────────┘"
echo ""
echo "Następny krok:"
echo "  1. Wklej powyższą wartość do terraform.tfvars"
echo "  2. terraform apply -target=module.bootstrap"
echo "  3. terraform apply -target=module.loadbalancer -target=module.firewall \\"
echo "       -target=module.routing -target=module.frontdoor -target=module.spoke1_app"
