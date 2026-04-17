#!/usr/bin/env bash
###############################################################################
# scripts/check-panorama.sh
# Sprawdza status Panoramy i otwiera RDP tunnel do DC (jump host dla GUI)
#
# UŻYCIE:
#   chmod +x scripts/check-panorama.sh
#   ./scripts/check-panorama.sh
#
# PRZEPŁYW DOSTĘPU DO GUI PANORAMY / FW:
#   1. Ten skrypt → otwiera RDP tunnel → localhost:33389 → DC (10.2.0.4)
#   2. Admin RDP do localhost:33389 (mstsc / Microsoft Remote Desktop)
#   3. Na DC: Chrome → https://10.0.0.10 (Panorama), https://10.0.0.4 (FW1)
#
# DLACZEGO TAK (ograniczenie Azure Bastion IpConnect):
#   --target-ip-address dozwala TYLKO porty 22 i 3389.
#   Port 443 (HTTPS GUI) wymaga --target-resource-id (nie IpConnect).
#   Zamiast tunelować port 443, używamy DC jako jump host z przeglądarką.
#
# WYMÓG: az CLI zalogowany (az login), terraform output dostępny
###############################################################################

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

BASTION_NAME="bastion-hub"
BASTION_RG="rg-transit-hub"
PANORAMA_VM="vm-panorama"
PANORAMA_IP="10.0.0.10"
DC_IP="10.2.0.4"
RDP_LOCAL_PORT="33389"

MAX_WAIT_MIN=20
INTERVAL_SEC=60

echo -e "${BLUE}══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Azure Transit VNet – Panorama Access Helper             ${NC}"
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

# ─── Krok 1: Czekaj na Panoramę ───────────────────────────────────────────
echo -e "${YELLOW}[INFO]${NC} Sprawdzam status VM Panoramy ($PANORAMA_VM w $BASTION_RG)..."
echo ""

attempt=0
MAX_ATTEMPTS=$((MAX_WAIT_MIN * 60 / INTERVAL_SEC))
VM_STATE="unknown"

while [ $attempt -lt $MAX_ATTEMPTS ]; do
  attempt=$((attempt + 1))
  elapsed_min=$(( (attempt - 1) * INTERVAL_SEC / 60 ))

  VM_STATE=$(az vm get-instance-view \
    --resource-group "$BASTION_RG" \
    --name "$PANORAMA_VM" \
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
  echo "   Sprawdź w Azure Portal: $BASTION_RG → $PANORAMA_VM → Status"
  exit 1
fi

# ─── Krok 2: Pokaż kompletne metody dostępu ───────────────────────────────
echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  METODY DOSTĘPU DO ŚRODOWISKA                           ${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${GREEN}[SSH] FW1 (Active):${NC}"
echo "  az network bastion ssh --name $BASTION_NAME --resource-group $BASTION_RG \\"
echo "    --target-ip-address 10.0.0.4 --auth-type password --username panadmin"
echo ""
echo -e "${GREEN}[SSH] FW2 (Passive):${NC}"
echo "  az network bastion ssh --name $BASTION_NAME --resource-group $BASTION_RG \\"
echo "    --target-ip-address 10.0.0.5 --auth-type password --username panadmin"
echo ""
echo -e "${GREEN}[SSH] Panorama:${NC}"
echo "  az network bastion ssh --name $BASTION_NAME --resource-group $BASTION_RG \\"
echo "    --target-ip-address $PANORAMA_IP --auth-type password --username panadmin"
echo ""
echo -e "${YELLOW}[GUI - HTTPS] Panorama / FW1 / FW2:${NC}"
echo "  → Workflow: RDP na DC (ten skrypt) → przeglądarka na DC:"
echo "    https://$PANORAMA_IP        (Panorama)"
echo "    https://10.0.0.4           (FW1 GUI)"
echo "    https://10.0.0.5           (FW2 GUI)"
echo "    ⚠️  Zaakceptuj certyfikat self-signed (ADVANCED → Proceed)"
echo ""
echo -e "${YELLOW}[Phase 2 panos provider] Tunel do Panoramy port 443:${NC}"
echo "  # Pobierz Panorama VM Resource ID:"
echo "  PANORAMA_ID=\$(terraform output -raw panorama_vm_id)"
echo "  # Uruchom tunel (--target-resource-id działa z dowolnym portem):"
echo "  az network bastion tunnel --name $BASTION_NAME --resource-group $BASTION_RG \\"
echo "    --target-resource-id \"\$PANORAMA_ID\" --resource-port 443 --port 44300"
echo ""

# ─── Krok 3: Otwórz RDP tunnel do DC ──────────────────────────────────────
echo -e "${BLUE}══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  OTWIERANIE RDP TUNNEL → DC (jump host dla GUI)         ${NC}"
echo -e "${BLUE}  localhost:${RDP_LOCAL_PORT} → DC (${DC_IP}:3389)              ${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}⚠️  Tunel działa w TRYBIE BLOKUJĄCYM – nie zamykaj tego terminala!${NC}"
echo -e "${YELLOW}   Otwórz NOWY terminal dla dalszych kroków.${NC}"
echo ""
echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  DALSZE KROKI (w NOWYM terminalu):                      ${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
echo ""
echo "  1. RDP do DC (po zestawieniu tunelu poniżej):"
echo "     Windows:  mstsc /v:localhost:${RDP_LOCAL_PORT}"
echo "     macOS:    Otwórz 'Microsoft Remote Desktop'"
echo "               → Add PC → localhost:${RDP_LOCAL_PORT}"
echo "     Login: dcadmin | Hasło: dc_admin_password z terraform.tfvars"
echo ""
echo "  2. Na DC – otwórz przeglądarkę (np. Chrome/Edge) i wejdź na:"
echo "     https://${PANORAMA_IP}   ← Panorama GUI"
echo "     https://10.0.0.4        ← FW1 GUI"
echo "     https://10.0.0.5        ← FW2 GUI"
echo "     ⚠️  Kliknij ADVANCED → Proceed to ... (certyfikat self-signed)"
echo ""
echo "  3. Na Panoramie (https://${PANORAMA_IP}):"
echo "     a) Aktywuj licencję:"
echo "        Panorama → Licenses → Activate feature using auth code"
echo "     b) Wygeneruj VM Auth Key:"
echo "        Panorama → Device Registration Auth Key → Generate"
echo "        Ważność: 8760 hours → SKOPIUJ klucz"
echo ""
echo "  4. Wklej klucz do terraform.tfvars:"
echo "     panorama_vm_auth_key = \"SKOPIOWANY-KLUCZ\""
echo ""
echo "  5. Uruchom Phase 1b (w nowym terminalu):"
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

# Uruchom RDP tunnel – blokuje terminal do Ctrl+C
echo -e "${GREEN}Uruchamiam RDP tunnel: ${BASTION_NAME} → DC (${DC_IP}:3389) → localhost:${RDP_LOCAL_PORT}${NC}"
echo -e "${GREEN}(IpConnect: --target-ip-address dozwala portów 22 i 3389)${NC}"
echo "(Zatrzymaj tunelowanie: Ctrl+C)"
echo ""

az network bastion tunnel \
  --name "$BASTION_NAME" \
  --resource-group "$BASTION_RG" \
  --target-ip-address "$DC_IP" \
  --resource-port 3389 \
  --port "$RDP_LOCAL_PORT"
