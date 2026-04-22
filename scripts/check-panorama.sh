#!/usr/bin/env bash
###############################################################################
# scripts/check-panorama.sh
# Helper script for managing Panorama and VM access via Azure Bastion
#
# ACCESS ARCHITECTURE (Management VNet):
#   Single Bastion Standard in Management VNet:
#     bastion-management  /  rg-transit-hub  /  10.255.1.0/26
#
#   Reachable VMs via peering:
#     Panorama:     10.255.0.4  (Management VNet – snet-management)
#     FW1 (mgmt):   10.110.255.4 (Transit Hub – snet-mgmt)
#     FW2 (mgmt):   10.110.255.5 (Transit Hub – snet-mgmt)
#     DC (App2):    10.113.0.4  (App2 VNet – snet-workload)
#
# ACCESS METHODS:
#   SSH  → --target-resource-id  (always works)
#   SSH  → --target-ip-address   (requires ip_connect_enabled=true + terraform apply)
#   Tunel → --target-resource-id (for Phase 2 / GUI via browser)
#   RDP  → az network bastion tunnel (DC)
#
# USAGE:
#   ./scripts/check-panorama.sh           → checks status + shows commands
#   ./scripts/check-panorama.sh --tunnel  → opens HTTPS tunnel to Panorama (port 44300)
#   ./scripts/check-panorama.sh --rdp     → opens RDP tunnel to DC (port 33389)
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

# Check az login
if ! az account show &>/dev/null; then
  echo -e "${RED}Not logged in to Azure CLI! Run: az login${NC}"
  exit 1
fi

###############################################################################
# Fetch VM resource IDs from terraform output
###############################################################################
echo -e "${YELLOW}[INFO]${NC} Fetching resource info (terraform output)..."

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
# Check Panorama status
###############################################################################
echo -e "${YELLOW}[INFO]${NC} Checking Panorama VM status ($PANORAMA_VM w $PANORAMA_RG)..."
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
  echo -e "       Run Phase 1a or check Azure Portal."
fi
echo ""

###############################################################################
# MODE: --tunnel → opens HTTPS tunnel to Panorama (Phase 2 / panos provider)
###############################################################################
if [[ "$MODE" == "--tunnel" ]]; then
  if [[ -z "$PANORAMA_ID" ]]; then
    echo -e "${RED}Missing panorama_vm_id in terraform output. Run Phase 1a first.${NC}"
    exit 1
  fi

  echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}  HTTPS Tunnel to Panorama (port ${HTTPS_TUNNEL_PORT})               ${NC}"
  echo -e "${CYAN}  Use: panos provider or curl https://127.0.0.1:${HTTPS_TUNNEL_PORT}${NC}"
  echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
  echo ""
  echo -e "${YELLOW}BLOCKING terminal — do not close! Open a NEW terminal.${NC}"
  echo ""
  echo "  Run Phase 2 in NEW TERMINAL window:"
  echo "    cd phase2-panorama-config/"
  echo "    terraform apply"
  echo ""
  echo "  Or generate vm-auth-key:"
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
# MODE: --rdp → opens RDP tunnel to DC
###############################################################################
if [[ "$MODE" == "--rdp" ]]; then
  if [[ -z "$DC_ID" ]]; then
    echo -e "${RED}Missing dc_vm_id in terraform output. Run Phase 1a (module.app2_dc) first.${NC}"
    exit 1
  fi

  echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}  RDP Tunnel to DC (${DC_IP}:3389 → localhost:${RDP_TUNNEL_PORT}) ${NC}"
  echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
  echo ""
  echo -e "${YELLOW}BLOCKING terminal — do not close! Open a NEW terminal.${NC}"
  echo ""
  echo "  NEXT STEPS (NEW terminal):"
  echo "    Windows: mstsc /v:localhost:${RDP_TUNNEL_PORT}"
  echo "    macOS:   Microsoft Remote Desktop → Add PC → localhost:${RDP_TUNNEL_PORT}"
  echo "    Login:   dcadmin | Password: dc_admin_password from terraform.tfvars"
  echo ""
  echo "  On DC (Edge Browser) → Panorama GUI:"
  echo "    https://${PANORAMA_IP}     ← Panorama"
  echo "    https://10.110.255.4      ← FW1 (mgmt)"
  echo "    https://10.110.255.5      ← FW2 (mgmt)"
  echo "    Click: ADVANCED → Proceed (self-signed certificate)"
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
# DEFAULT MODE: show status and access commands
###############################################################################
echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  ACCESS METHODS via Bastion: ${BASTION_NAME}          ${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
echo ""

# Panorama SSH
echo -e "${GREEN}${BOLD}[SSH] Panorama (${PANORAMA_IP}):${NC}"
echo -e "  ${YELLOW}Method A — always works:${NC}"
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
echo -e "  ${YELLOW}Method B – after 'terraform apply -target=module.networking' (ip_connect_enabled=true):${NC}"
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
echo "  Or manually:"
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
echo -e "${CYAN}  PHASE 2 – Panorama Configuration via XML API          ${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
echo ""
echo "  Terminal 1 (HTTPS tunel – keep it open):"
echo "    ./scripts/check-panorama.sh --tunnel"
echo ""
echo "  Terminal 2 (Phase 2 apply):"
echo "    cd phase2-panorama-config/"
echo "    # Fill in terraform.tfvars (password, auth_code, CIDRs)"
echo "    terraform apply"
echo "    # Terraform automates:"
echo "    #   1. Waits for Panorama API (max 20 min)"
echo "    #   2. Sets hostname via XML API"
echo "    #   3. Activates license via XML API (if auth_code provided)"
echo "    #   4. Configures Template Stack, Device Group, policies (panos provider)"
echo "    #   5. Commits Panorama"
echo ""

# VM Auth Key
echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  VM AUTH KEY – after Panorama activation          ${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
echo ""
echo "  Automatically (via HTTPS tunel, port $HTTPS_TUNNEL_PORT):"
echo "    PANORAMA_IP=127.0.0.1 PANORAMA_PORT=$HTTPS_TUNNEL_PORT \\"
echo "    ./scripts/generate-vm-auth-key.sh"
echo ""
echo "  Or in Panorama via GUI:"
echo "    https://127.0.0.1:$HTTPS_TUNNEL_PORT → Panorama → Devices → VM Auth Key → Generate"
echo ""
echo "  AFter obtaining the auth key → terraform.tfvars:"
echo "    panorama_vm_auth_key = \"2:XXXXXX...\""
echo "  Then:"
echo "    terraform apply -target=module.bootstrap  # updates FW init-cfg"
echo "    terraform apply  # deploys FW, LB, routing, frontdoor"
echo ""