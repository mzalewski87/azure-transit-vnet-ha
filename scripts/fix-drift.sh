#!/usr/bin/env bash
###############################################################################
# scripts/fix-drift.sh
# Fix Terraform State drift
#
# WHEN TO RUN:
#   When terraform apply returns error:
#   "A resource with the ID ... already exists - needs to be imported"
#
# REQUIREMENTS:
#   - az CLI logged in: az login
#   - terraform init executed in project root directory
#   - Run from project root directory (azure_ha_project/)
#
# USAGE:
#   chmod +x scripts/fix-drift.sh
#   ./scripts/fix-drift.sh
#
# What this script does:
#   1. Imports azurerm_virtual_machine_extension "dc_promote" into TF state
#      (extension exists in Azure because DC was already promoted, but TF does not know)
#   2. Removes old azurerm_marketplace_agreement from state (if present)
#      Code changed to null_resource — old resources in state will conflict
###############################################################################

set -euo pipefail

# ─── Colors for readability ──────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# ─── Fetch Subscription ID ─────────────────────────────────────────────────
info "Fetching Subscription ID from active az session..."
SUB_ID=$(az account show --query id -o tsv 2>/dev/null) || {
  error "Cannot fetch Subscription ID. Make sure you are logged in: az login"
  exit 1
}
info "Subscription ID: ${SUB_ID}"

# You can also set it manually:
# SUB_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

echo ""
info "======================================================"
info " STEP 1: Remove old azurerm_marketplace_agreement from state"
info "======================================================"
info "(Kod changed to null_resource – stary resource type generates conflict)"
echo ""

# Remove from state if present (no error if missing)
AGREEMENTS=(
  "module.firewall.azurerm_marketplace_agreement.panos_byol"
  "module.panorama.azurerm_marketplace_agreement.panorama"
)

for agreement in "${AGREEMENTS[@]}"; do
  if terraform state list 2>/dev/null | grep -q "^${agreement}$"; then
    warn "Removing from state: ${agreement}"
    terraform state rm "${agreement}"
    info "Removed: ${agreement}"
  else
    info "Not in state (OK): ${agreement}"
  fi
done

echo ""
info "======================================================"
info " STEP 2: Import dc_promote extension to state"
info "======================================================"
info "(Extension exists in Azure, DC is already promoted)"
echo ""

DC_EXT_ID="/subscriptions/${SUB_ID}/resourceGroups/rg-spoke2-dc/providers/Microsoft.Compute/virtualMachines/vm-spoke2-dc/extensions/promote-to-dc"
DC_EXT_STATE="module.spoke2_dc.azurerm_virtual_machine_extension.dc_promote"

# Check if extension exists in Azure
if az vm extension show \
    --resource-group rg-spoke2-dc \
    --vm-name vm-spoke2-dc \
    --name promote-to-dc \
    --query "provisioningState" -o tsv 2>/dev/null | grep -q "Succeeded"; then

  # Check if already in state
  if terraform state list 2>/dev/null | grep -q "^${DC_EXT_STATE}$"; then
    info "dc_promote already in Terraform state — nothing to do"
  else
    info "Importing dc_promote extension into Terraform state..."
    terraform import "${DC_EXT_STATE}" "${DC_EXT_ID}"
    info "Import completed successfully!"
  fi
else
  warn "Extension promote-to-dc does not exist in Azure or is not in Succeeded state."
  warn "Skip this step or check portal: Portal → vm-spoke2-dc → Extensions"
fi

echo ""
info "======================================================"
info " STEP 3: State verification"
info "======================================================"
echo ""
terraform state list | grep -E "(spoke2_dc|marketplace|panorama_terms|panos_terms)" || true

echo ""
info "======================================================"
info " DONE! You can now retry:"
info "   terraform plan -out=tfplan && terraform apply tfplan"
info "======================================================"
