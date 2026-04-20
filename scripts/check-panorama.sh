#!/usr/bin/env bash
###############################################################################
# scripts/check-panorama.sh
# Helper skryptu do zarządzania dostępem do Panoramy i VM przez Azure Bastion
#
# ARCHITEKTURA DOSTĘPU (nowa – Management VNet):
#   Jeden Bastion Standard w Management VNet:
#     bastion-management  /  rg-transit-hub  /  10.255.1.0/26
#
#   Dostępne VMs przez peering:
#     Panorama:     10.255.0.4  (Management VNet – snet-management)
#     FW1 (mgmt):   10.110.255.4 (Transit Hub – snet-mgmt)
#     FW2 (mgmt):   10.110.255.5 (Transit Hub – snet-mgmt)
#     DC (App2):    10.113.0.4  (App2 VNet – snet-workload)
#
# METODY DOSTĘPU:
#   SSH  → --target-resource-id  (zawsze działa)
#   SSH  → --target-ip-address   (wymaga ip_connect_enabled=true + terraform apply)
#   Tunel → --target-resource-id (dla Phase 2 / GUI przez przeglądarkę)
#   RDP  → az network bastion tunnel (DC)
#
# UŻYCIE:
#   ./scripts/check-panorama.sh           → sprawdza status + pokazuje komendy
#   ./scripts/check-panorama.sh --tunnel  → otwiera HTTPS tunel do Panoramy (port 44300)
#   ./scripts/check-panorama.sh --rdp     → otwiera RDP tunel do DC (port 33389)
###############################################################################

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

BASTION_NAME="bastion-management"
BASTION_RG="rg-transit-hub"
PANORAMA_VM="vm-panorama"
PANORAMA_RG="rg-transit-hub"
PANORAMA_IP="10.255.0.4"
DC_IP="10.113.0.4"
HTTPS_TUNNEL_PORT="44300"
RDP_TUNNEL_PORT="33389"
MODE="${1:-}"

echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}${BOLD}  Azure Transit VNet – Access Helper                      ${NC}"
echo -e "${BLUE}${BOLD}  Bastion: ${BASTION_NAME} (${BASTION_RG})        ${NC}"
echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════════════${NC}"
echo ""

# Sprawdź az login
if ! az account show &>/dev/null; then
  echo -e "${RED}Nie jesteś zalogowany do Azure CLI! Uruchom: az login${NC}"
  exit 1
fi

###############################################################################
# Pobierz VM resource IDs z terraform output
###############################################################################
echo -e "${YELLOW}[INFO]${NC} Pobieranie informacji o zasobach (terraform output)..."

PANORAMA_ID=""
DC_ID=""
FW1_ID=""
FW2_ID=""

if terraform output -raw panorama_vm_id &>/dev/null 2>/dev/null; then
  PANORAMA_ID=$(terraform output -raw panorama_vm_id 2>/dev/null || echo "")
fi
if terraform output -raw dc_vm_id &>/dev/null 2>/dev/null; then
  DC_ID=$(terraform output -raw dc_vm_id 2>/dev/null || echo "")
fi
if terraform output -raw fw1_vm_id &>/dev/null 2>/dev/null; then
  FW1_ID=$(terraform output -raw fw1_vm_id 2>/dev/null || echo "")
fi
if terraform output -raw fw2_vm_id &>/dev/null 2>/dev/null; then
  FW2_ID=$(terraform output -raw fw2_vm_id 2>/dev/null || echo "")
fi

###############################################################################
# Sprawdź status Panoramy
###############################################################################
echo -e "${YELLOW}[INFO]${NC} Sprawdzam status VM Panoramy ($PANORAMA_VM w $PANORAMA_RG)..."
echo ""

VM_STATE=$(az vm get-instance-view \
  --resource-group "$PANORAMA_RG" \
  --name "$PANORAMA_VM" \
  --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus" \
  --output tsv 2>/dev/null || echo "unknown")

if [[ "$VM_STATE" == "VM running" ]]; then
  echo -e "${GREEN}[OK] Panorama: VM Running${NC}"
else
  echo -e "${YELLOW}[WARN] Panorama: $VM_STATE${NC}"
  echo -e "       Uruchom Phase 1a lub sprawdź Portal Azure."
fi
echo ""

###############################################################################
# TRYB: --tunnel → otwiera HTTPS tunel do Panoramy (Phase 2 / panos provider)
###############################################################################
if [[ "$MODE" == "--tunnel" ]]; then
  if [[ -z "$PANORAMA_ID" ]]; then
    echo -e "${RED}Brak panorama_vm_id w terraform output. Uruchom Phase 1a najpierw.${NC}"
    exit 1
  fi

  echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}  HTTPS Tunel do Panoramy (port ${HTTPS_TUNNEL_PORT})               ${NC}"
  echo -e "${CYAN}  Używaj: panos provider lub curl https://127.0.0.1:${HTTPS_TUNNEL_PORT}${NC}"
  echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
  echo ""
  echo -e "${YELLOW}Terminal BLOKUJĄCY – nie zamykaj! Otwórz NOWY terminal.${NC}"
  echo ""
  echo "  W NOWYM terminalu uruchom Phase 2:"
  echo "    cd phase2-panorama-config/"
  echo "    terraform apply"
  echo ""
  echo "  Lub generuj vm-auth-key:"
  echo "    PANORAMA_IP=127.0.0.1 PANORAMA_PORT=${HTTPS_TUNNEL_PORT} \\"
  echo "    ./scripts/generate-vm-auth-key.sh"
  echo ""

  az network bastion tunnel \
    --name "$BASTION_NAME" \
    --resource-group "$BASTION_RG" \
    --target-resource-id "$PANORAMA_ID" \
    --resource-port 443 \
    --port "$HTTPS_TUNNEL_PORT"
  exit 0
fi

###############################################################################
# TRYB: --rdp → otwiera RDP tunel do DC
###############################################################################
if [[ "$MODE" == "--rdp" ]]; then
  if [[ -z "$DC_ID" ]]; then
    echo -e "${RED}Brak dc_vm_id w terraform output. Uruchom Phase 1a (module.app2_dc) najpierw.${NC}"
    exit 1
  fi

  echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}  RDP Tunel do DC (${DC_IP}:3389 → localhost:${RDP_TUNNEL_PORT}) ${NC}"
  echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
  echo ""
  echo -e "${YELLOW}Terminal BLOKUJĄCY – nie zamykaj! Otwórz NOWY terminal.${NC}"
  echo ""
  echo "  DALSZE KROKI (NOWY terminal):"
  echo "    Windows: mstsc /v:localhost:${RDP_TUNNEL_PORT}"
  echo "    macOS:   Microsoft Remote Desktop → Add PC → localhost:${RDP_TUNNEL_PORT}"
  echo "    Login:   dcadmin | Hasło: dc_admin_password z terraform.tfvars"
  echo ""
  echo "  Na DC (Chrome/Edge) → Panorama GUI:"
  echo "    https://${PANORAMA_IP}     ← Panorama"
  echo "    https://10.110.255.4      ← FW1 (mgmt)"
  echo "    https://10.110.255.5      ← FW2 (mgmt)"
  echo "    Kliknij: ADVANCED → Proceed (certyfikat self-signed)"
  echo ""

  az network bastion tunnel \
    --name "$BASTION_NAME" \
    --resource-group "$BASTION_RG" \
    --target-resource-id "$DC_ID" \
    --resource-port 3389 \
    --port "$RDP_TUNNEL_PORT"
  exit 0
fi

###############################################################################
# TRYB domyślny: pokaż status i komendy dostępu
###############################################################################
echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  METODY DOSTĘPU przez Bastion: ${BASTION_NAME}          ${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
echo ""

# Panorama SSH
echo -e "${GREEN}${BOLD}[SSH] Panorama (${PANORAMA_IP}):${NC}"
echo -e "  ${YELLOW}Metoda A – zawsze działa:${NC}"
if [[ -n "$PANORAMA_ID" ]]; then
  echo "    az network bastion ssh --name $BASTION_NAME --resource-group $BASTION_RG \\"
  echo "      --target-resource-id \"$PANORAMA_ID\" \\"
  echo "      --auth-type password --username panadmin"
else
  echo '    PANORAMA_ID=$(terraform output -raw panorama_vm_id)'
  echo "    az network bastion ssh --name $BASTION_NAME --resource-group $BASTION_RG \\"
  echo '      --target-resource-id "$PANORAMA_ID" --auth-type password --username panadmin'
fi
echo ""
echo -e "  ${YELLOW}Metoda B – po 'terraform apply -target=module.networking' (ip_connect_enabled=true):${NC}"
echo "    az network bastion ssh --name $BASTION_NAME --resource-group $BASTION_RG \\"
echo "      --target-ip-address $PANORAMA_IP --auth-type password --username panadmin"
echo ""

# FW SSH
echo -e "${GREEN}${BOLD}[SSH] FW1 mgmt (10.110.255.4):${NC}"
if [[ -n "$FW1_ID" ]]; then
  echo "    az network bastion ssh --name $BASTION_NAME --resource-group $BASTION_RG \\"
  echo "      --target-resource-id \"$FW1_ID\" --auth-type password --username panadmin"
else
  echo '    FW1_ID=$(terraform output -raw fw1_vm_id)'
  echo "    az network bastion ssh --name $BASTION_NAME --resource-group $BASTION_RG \\"
  echo '      --target-resource-id "$FW1_ID" --auth-type password --username panadmin'
fi
echo ""

echo -e "${GREEN}${BOLD}[SSH] FW2 mgmt (10.110.255.5):${NC}"
if [[ -n "$FW2_ID" ]]; then
  echo "    az network bastion ssh --name $BASTION_NAME --resource-group $BASTION_RG \\"
  echo "      --target-resource-id \"$FW2_ID\" --auth-type password --username panadmin"
else
  echo '    FW2_ID=$(terraform output -raw fw2_vm_id)'
  echo "    az network bastion ssh --name $BASTION_NAME --resource-group $BASTION_RG \\"
  echo '      --target-resource-id "$FW2_ID" --auth-type password --username panadmin'
fi
echo ""

# HTTPS tunnel
echo -e "${GREEN}${BOLD}[HTTPS Tunel] Panorama GUI / Phase 2 panos provider (port ${HTTPS_TUNNEL_PORT}):${NC}"
echo "    ./scripts/check-panorama.sh --tunnel"
echo ""
echo "  Lub ręcznie:"
if [[ -n "$PANORAMA_ID" ]]; then
  echo "    az network bastion tunnel --name $BASTION_NAME --resource-group $BASTION_RG \\"
  echo "      --target-resource-id \"$PANORAMA_ID\" --resource-port 443 --port $HTTPS_TUNNEL_PORT"
else
  echo '    PANORAMA_ID=$(terraform output -raw panorama_vm_id)'
  echo "    az network bastion tunnel --name $BASTION_NAME --resource-group $BASTION_RG \\"
  echo '      --target-resource-id "$PANORAMA_ID" --resource-port 443 --port '"$HTTPS_TUNNEL_PORT"
fi
echo ""

# RDP do DC
echo -e "${GREEN}${BOLD}[RDP] DC (${DC_IP}:3389 → localhost:${RDP_TUNNEL_PORT}):${NC}"
echo "    ./scripts/check-panorama.sh --rdp"
echo ""

# Phase 2
echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  PHASE 2 – Konfiguracja Panoramy przez XML API          ${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
echo ""
echo "  Terminal 1 (HTTPS tunel – zostaw otwarty):"
echo "    ./scripts/check-panorama.sh --tunnel"
echo ""
echo "  Terminal 2 (Phase 2 apply):"
echo "    cd phase2-panorama-config/"
echo "    # Uzupełnij terraform.tfvars (hasło, auth_code, CIDRy)"
echo "    terraform apply"
echo "    # Terraform automatycznie:"
echo "    #   1. Czeka na Panorama API (max 20 min)"
echo "    #   2. Ustawia hostname przez XML API"
echo "    #   3. Aktywuje licencję przez XML API (jeśli podano auth_code)"
echo "    #   4. Konfiguruje Template Stack, Device Group, policies (panos provider)"
echo "    #   5. Commituje Panoramę"
echo ""

# VM Auth Key
echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  VM AUTH KEY – po aktywacji licencji Panoramy            ${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
echo ""
echo "  Automatycznie (przez HTTPS tunel, port $HTTPS_TUNNEL_PORT):"
echo "    PANORAMA_IP=127.0.0.1 PANORAMA_PORT=$HTTPS_TUNNEL_PORT \\"
echo "    ./scripts/generate-vm-auth-key.sh"
echo ""
echo "  Lub w Panoramie przez GUI:"
echo "    https://127.0.0.1:$HTTPS_TUNNEL_PORT → Panorama → Devices → VM Auth Key → Generate"
echo ""
echo "  Po uzyskaniu klucza → terraform.tfvars:"
echo "    panorama_vm_auth_key = \"2:XXXXXX...\""
echo "  Następnie:"
echo "    terraform apply -target=module.bootstrap  # aktualizuje FW init-cfg"
echo "    terraform apply  # wdraża FW, LB, routing, frontdoor"
echo ""
