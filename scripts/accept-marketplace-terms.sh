#!/usr/bin/env bash
###############################################################################
# accept-marketplace-terms.sh
#
# Accepts Azure Marketplace EULAs for the two PANW BYOL images this project
# deploys. Run ONCE per Azure subscription before Phase 1a `terraform apply`.
# Idempotent — safe to re-run.
#
# Without this, Phase 1a fails on module.panorama with:
#   ResourcePurchaseValidationFailed: You have not accepted the legal terms
#   on this subscription ... Offer details: publisher='paloaltonetworks',
#   offer='panorama', sku='byol'.
#
# Hits every fresh subscription (Torque/lab subs that get re-provisioned
# every 5 weeks). The Ubuntu / Windows Server / AKS images we also use
# are stock and do NOT need this step.
###############################################################################

set -euo pipefail

SUB_ID=$(az account show --query id -o tsv 2>/dev/null || true)
if [ -z "$SUB_ID" ]; then
  echo "[ERROR] az CLI not logged in. Run 'az login' first."
  exit 1
fi
SUB_NAME=$(az account show --query name -o tsv)
echo "Targeting subscription: $SUB_NAME ($SUB_ID)"
echo ""

accept() {
  local OFFER="$1"
  local PLAN="$2"
  local LABEL="$3"
  printf "  %-30s ... " "$LABEL"
  if az vm image terms accept --publisher paloaltonetworks --offer "$OFFER" --plan "$PLAN" --only-show-errors >/dev/null 2>&1; then
    local ACCEPTED=$(az vm image terms show --publisher paloaltonetworks --offer "$OFFER" --plan "$PLAN" --query accepted -o tsv 2>/dev/null)
    echo "accepted=$ACCEPTED"
  else
    echo "FAILED"
    exit 1
  fi
}

echo "=== Accepting PANW Marketplace BYOL terms ==="
accept "panorama"      "byol" "Panorama BYOL"
accept "vmseries-flex" "byol" "VM-Series Flex BYOL"

echo ""
echo "[OK] Marketplace terms accepted for subscription $SUB_ID."
echo "     You can now run 'terraform apply' for Phase 1a."
