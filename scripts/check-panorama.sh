#!/usr/bin/env bash
###############################################################################
# scripts/check-panorama.sh
# Sprawdza status Panoramy i otwiera Azure Bastion Tunnel do GUI
#
# UŻYCIE:
#   chmod +x scripts/check-panorama.sh
#   ./scripts/check-panorama.sh
#
# Co robi skrypt:
#   1. Sprawdza status VM Panoramy (az vm get-instance-view)
#   2. Gdy VM Running → otwiera Bastion Tunnel na localhost:44300
#   3. Podaje dalsze instrukcje (Phase 1b)
#
# WYMÓG: az CLI zalogowany (az login), terraform output dostępny
###############################################################################

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

BASTION_NAME="bastion-hub"
BASTION_RG="rg-transit-hub"
PANORAMA_IP="10.0.0.10"
LOCAL_PORT="44300"
REMOTE_PORT="443"

MAX_WAIT_MIN=20
INTERVAL_SEC=60

echo -e "${BLUE}══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Azure Transit VNet – Panorama Bastion Access Helper      ${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════════════${NC}"
echo ""

# Sprawdź czy az CLI jest zalogowany
if ! az account show &>/dev/null; then
  echo -e "${RED}❌ Nie jesteś zalogowany do Azure CLI!${NC}"
  echo "   Uruchom: az login"
  exit 1
fi

# Pobierz opcjonalnie bastion name/rg z terraform output
if terraform output -raw hub_bastion_name &>/dev/null 2>/dev/null; then
  BASTION_NAME=$(terraform output -raw hub_bastion_name 2>/dev/null) || BASTION_NAME="bastion-hub"
  BASTION_RG=$(terraform output -raw hub_bastion_rg 2>/dev/null) || BASTION_RG="rg-transit-hub"
fi

echo -e "${YELLOW}[INFO]${NC} Sprawdzam status VM Panoramy (vm-panorama w $BASTION_RG)..."
echo ""

attempt=0
MAX_ATTEMPTS=$((MAX_WAIT_MIN * 60 / INTERVAL_SEC))

while [ $attempt -lt $MAX_ATTEMPTS ]; do
  attempt=$((attempt + 1))
  elapsed_min=$(( (attempt - 1) * INTERVAL_SEC / 60 ))

  VM_STATE=$(az vm get-instance-view \
    --resource-group "$BASTION_RG" \
    --name "vm-panorama" \
    --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus" \
    --output tsv 2>/dev/null) || VM_STATE="unknown"

  if [[ "$VM_STATE" == "VM running" ]]; then
    echo -e "${GREEN}✅ Panorama VM Running! (po ~${elapsed_min} min)${NC}"
    echo ""
    break
  fi

  echo -e "${YELLOW}[${elapsed_min} min]${NC} Panorama: '$VM_STATE'. Czekam ${INTERVAL_SEC}s..."
  sleep $INTERVAL_SEC
done

if [[ "$VM_STATE" != "VM running" ]]; then
  echo -e "${RED}❌ Panorama nie uruchomiona po ${MAX_WAIT_MIN} min.${NC}"
  echo "   Sprawdź w Azure Portal: rg-transit-hub → vm-panorama → Status"
  exit 1
fi

echo -e "${BLUE}══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  OTWIERANIE AZURE BASTION TUNNEL                         ${NC}"
echo -e "${BLUE}  Panorama GUI: https://localhost:${LOCAL_PORT}              ${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}⚠️  Tunel działa w TRYBIE BLOKUJĄCYM – nie zamykaj tego terminala!${NC}"
echo -e "${YELLOW}   Otwórz NOWY terminal dla dalszych kroków.${NC}"
echo ""
echo -e "${YELLOW}══════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}  DALSZE KROKI (w NOWYM terminalu po otwarciu tunelu):    ${NC}"
echo -e "${YELLOW}══════════════════════════════════════════════════════════${NC}"
echo ""
echo "  1. Otwórz: https://localhost:${LOCAL_PORT}"
echo "     ⚠️  Zaakceptuj certyfikat self-signed (ADVANCED → Proceed)"
echo "     Login: panadmin  |  Hasło: z terraform.tfvars"
echo ""
echo "  2. AKTYWUJ LICENCJĘ (jeśli nie aktywowała się z init-cfg):"
echo "     Panorama → Licenses → Activate feature using auth code"
echo "     → Wpisz panorama_auth_code z terraform.tfvars"
echo ""
echo "  3. WYGENERUJ VM AUTH KEY:"
echo "     Panorama → Device Registration Auth Key → Generate"
echo "     → Ważność: 8760 hours (1 rok)"
echo "     → SKOPIUJ klucz"
echo ""
echo "  4. WKLEJ KLUCZ do terraform.tfvars (w katalogu głównym):"
echo "     panorama_vm_auth_key = \"SKOPIOWANY-KLUCZ\""
echo ""
echo "  5. URUCHOM Phase 1b (w nowym terminalu):"
echo "     terraform apply -target=module.bootstrap"
echo "     terraform apply \\"
echo "       -target=module.loadbalancer \\"
echo "       -target=module.firewall \\"
echo "       -target=module.routing \\"
echo "       -target=module.frontdoor \\"
echo "       -target=module.spoke1_app \\"
echo "       -target=module.spoke2_dc"
echo ""
echo "════════════════════════════════════════════════════════════"
echo ""

# Uruchom tunel – blokuje terminal do Ctrl+C
echo -e "${GREEN}Uruchamiam tunel: ${BASTION_NAME} → ${PANORAMA_IP}:${REMOTE_PORT} → localhost:${LOCAL_PORT}${NC}"
echo "(Zatrzymaj tunelowanie: Ctrl+C)"
echo ""

az network bastion tunnel \
  --name "$BASTION_NAME" \
  --resource-group "$BASTION_RG" \
  --target-ip-address "$PANORAMA_IP" \
  --resource-port "$REMOTE_PORT" \
  --port "$LOCAL_PORT"
