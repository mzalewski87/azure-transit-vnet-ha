#!/usr/bin/env bash
###############################################################################
# scripts/check-panorama.sh
# Sprawdza status Panoramy i otwiera RDP tunnel do DC (jump host dla GUI)
#
# ARCHITEKTURA DOSTEPU:
#   Jeden Bastion (Spoke2) obsluguje wszystko:
#   - RDP do DC (IpConnect, port 3389) → DC jest jump hostem dla GUI
#   - SSH do FW/Panoramy (IpConnect, port 22) przez Hub-Spoke2 VNet peering
#   - HTTPS tunnel do Panoramy (--target-resource-id, port 443) → Phase 2
#
# PRZEPŁYW GUI PANORAMY / FW:
#   1. Ten skrypt → Spoke2 Bastion → RDP tunnel → localhost:33389 → DC
#   2. RDP do localhost:33389 → DC (vm-spoke2-dc, 10.2.0.4)
#   3. Na DC: Chrome → https://10.0.0.10 (Panorama), https://10.0.0.4 (FW1)
#
# WYMÓG: az CLI zalogowany, terraform apply zakonczone (DC musi istniec)
###############################################################################

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

BASTION_NAME="bastion-spoke2"
BASTION_RG="rg-spoke2-dc"
PANORAMA_VM="vm-panorama"
PANORAMA_RG="rg-transit-hub"
PANORAMA_IP="10.0.0.10"
DC_IP="10.2.0.4"
RDP_LOCAL_PORT="33389"

MAX_WAIT_MIN=20
INTERVAL_SEC=60

echo -e "${BLUE}══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Azure Transit VNet – Panorama Access Helper             ${NC}"
echo -e "${BLUE}  Spoke2 Bastion (bastion-spoke2) → DC → GUI             ${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════════════${NC}"
echo ""

if ! az account show &>/dev/null; then
  echo -e "${RED}Nie jestes zalogowany do Azure CLI! Uruchom: az login${NC}"
  exit 1
fi

# Pobierz opcjonalnie z terraform output
if terraform output -raw spoke2_bastion_name &>/dev/null 2>/dev/null; then
  BASTION_NAME=$(terraform output -raw spoke2_bastion_name 2>/dev/null) || BASTION_NAME="bastion-spoke2"
  BASTION_RG=$(terraform output -raw spoke2_bastion_rg 2>/dev/null) || BASTION_RG="rg-spoke2-dc"
fi

# Krok 1: Czekaj na Panorame
echo -e "${YELLOW}[INFO]${NC} Sprawdzam status VM Panoramy ($PANORAMA_VM w $PANORAMA_RG)..."
echo ""

attempt=0
MAX_ATTEMPTS=$((MAX_WAIT_MIN * 60 / INTERVAL_SEC))
VM_STATE="unknown"

while [ $attempt -lt $MAX_ATTEMPTS ]; do
  attempt=$((attempt + 1))
  elapsed_min=$(( (attempt - 1) * INTERVAL_SEC / 60 ))

  VM_STATE=$(az vm get-instance-view \
    --resource-group "$PANORAMA_RG" \
    --name "$PANORAMA_VM" \
    --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus" \
    --output tsv 2>/dev/null) || VM_STATE="unknown"

  if [[ "$VM_STATE" == "VM running" ]]; then
    echo -e "${GREEN}Panorama VM Running! (po ~${elapsed_min} min)${NC}"
    echo ""
    break
  fi

  echo -e "${YELLOW}[${elapsed_min} min]${NC} Panorama: '$VM_STATE'. Czekam ${INTERVAL_SEC}s..."
  sleep $INTERVAL_SEC
done

if [[ "$VM_STATE" != "VM running" ]]; then
  echo -e "${RED}Panorama nie uruchomiona po ${MAX_WAIT_MIN} min. Sprawdz Azure Portal.${NC}"
  exit 1
fi

# Krok 2: Pokaz wszystkie metody dostepu
echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  METODY DOSTEPU – Spoke2 Bastion (bastion-spoke2)       ${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${GREEN}[SSH] FW1 (Active, 10.0.0.4):${NC}"
echo "  az network bastion ssh --name $BASTION_NAME --resource-group $BASTION_RG \\"
echo "    --target-ip-address 10.0.0.4 --auth-type password --username panadmin"
echo ""
echo -e "${GREEN}[SSH] FW2 (Passive, 10.0.0.5):${NC}"
echo "  az network bastion ssh --name $BASTION_NAME --resource-group $BASTION_RG \\"
echo "    --target-ip-address 10.0.0.5 --auth-type password --username panadmin"
echo ""
echo -e "${GREEN}[SSH] Panorama (10.0.0.10):${NC}"
echo "  az network bastion ssh --name $BASTION_NAME --resource-group $BASTION_RG \\"
echo "    --target-ip-address $PANORAMA_IP --auth-type password --username panadmin"
echo ""
echo -e "${YELLOW}[GUI - HTTPS] Panorama / FW1 / FW2:${NC}"
echo "  Workflow: RDP na DC (ten skrypt) → przeglądarka na DC:"
echo "    https://${PANORAMA_IP}   (Panorama GUI)"
echo "    https://10.0.0.4        (FW1 GUI)"
echo "    https://10.0.0.5        (FW2 GUI)"
echo "    Zaakceptuj certyfikat self-signed: ADVANCED → Proceed to ..."
echo ""
echo -e "${YELLOW}[Phase 2 panos provider] Tunel HTTPS do Panoramy port 443:${NC}"
echo "  PANORAMA_ID=\$(terraform output -raw panorama_vm_id)"
echo "  az network bastion tunnel --name $BASTION_NAME --resource-group $BASTION_RG \\"
echo "    --target-resource-id \"\$PANORAMA_ID\" --resource-port 443 --port 44300"
echo ""

# Krok 3: Otwórz RDP tunnel do DC
echo -e "${BLUE}══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  OTWIERANIE RDP TUNNEL → DC (${DC_IP}:3389)             ${NC}"
echo -e "${BLUE}  localhost:${RDP_LOCAL_PORT} → DC → przegladarka → Panorama/FW GUI ${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}Terminal BLOKUJACY – nie zamykaj! Otwórz NOWY terminal.${NC}"
echo ""
echo "  DALSZE KROKI (w NOWYM terminalu):"
echo ""
echo "  1. RDP do DC:"
echo "     Windows: mstsc /v:localhost:${RDP_LOCAL_PORT}"
echo "     macOS:   Microsoft Remote Desktop → Add PC → localhost:${RDP_LOCAL_PORT}"
echo "     Login: dcadmin | Haslo: dc_admin_password z terraform.tfvars"
echo ""
echo "  2. Na DC – Chrome/Edge:"
echo "     https://${PANORAMA_IP}   Panorama GUI"
echo "     https://10.0.0.4        FW1 GUI"
echo "     https://10.0.0.5        FW2 GUI"
echo "     Kliknij ADVANCED → Proceed to ... (certyfikat self-signed)"
echo ""
echo "  3. W Panoramie:"
echo "     a) Aktywuj licencje: Panorama → Licenses → Activate"
echo "     b) Wygeneruj VM Auth Key: Device Registration Auth Key → Generate"
echo "        Waznosc: 8760 hours → KOPIUJ klucz"
echo ""
echo "  4. Wklej do terraform.tfvars:"
echo "     panorama_vm_auth_key = \"KLUCZ\""
echo ""
echo "  5. Uruchom pozostale moduły:"
echo "     terraform apply -target=module.bootstrap"
echo "     terraform apply -target=module.loadbalancer -target=module.firewall \\"
echo "       -target=module.routing -target=module.frontdoor -target=module.spoke1_app"
echo ""
echo "════════════════════════════════════════════════════════════"
echo ""

echo -e "${GREEN}Uruchamiam RDP tunnel: $BASTION_NAME → DC (${DC_IP}:3389) → localhost:${RDP_LOCAL_PORT}${NC}"
echo "(Zatrzymaj: Ctrl+C)"
echo ""

az network bastion tunnel \
  --name "$BASTION_NAME" \
  --resource-group "$BASTION_RG" \
  --target-ip-address "$DC_IP" \
  --resource-port 3389 \
  --port "$RDP_LOCAL_PORT"
