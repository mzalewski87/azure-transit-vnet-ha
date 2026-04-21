#!/usr/bin/env bash
###############################################################################
# Import existing bootstrap files into Terraform state
#
# Use this script when terraform apply fails with:
#   "A resource with the ID ... already exists - to be managed via Terraform
#    this resource needs to be imported into the State"
#
# This typically happens after a partial failure where files were created
# in Azure but Terraform state was not updated.
#
# Usage: bash scripts/import-bootstrap-files.sh
# (run from the Terraform project root directory)
###############################################################################
set -euo pipefail

# Get SA name from Terraform state
SA_NAME=$(terraform output -raw bootstrap_storage_account_name 2>/dev/null || echo "")

if [ -z "$SA_NAME" ]; then
  echo "Could not get SA name from terraform output."
  echo "Please provide the Storage Account name:"
  read -r SA_NAME
fi

BASE="https://${SA_NAME}.file.core.windows.net/bootstrap"

echo "=== Importing bootstrap files from SA: ${SA_NAME} ==="

declare -A FILES=(
  ["module.bootstrap.azurerm_storage_share_file.fw1_init_cfg"]="${BASE}/fw1/config/init-cfg.txt"
  ["module.bootstrap.azurerm_storage_share_file.fw1_authcodes"]="${BASE}/fw1/license/authcodes"
  ["module.bootstrap.azurerm_storage_share_file.fw2_init_cfg"]="${BASE}/fw2/config/init-cfg.txt"
  ["module.bootstrap.azurerm_storage_share_file.fw2_authcodes"]="${BASE}/fw2/license/authcodes"
)

for resource in "${!FILES[@]}"; do
  id="${FILES[$resource]}"
  echo ""
  echo "--- Importing: $resource"
  
  # Check if already in state
  if terraform state show "$resource" &>/dev/null; then
    echo "  Already in state, removing first..."
    terraform state rm "$resource" 2>/dev/null || true
  fi
  
  terraform import "$resource" "$id" 2>&1 || {
    echo "  [WARN] Import failed for $resource (file may not exist in Azure yet)"
  }
done

echo ""
echo "=== Import complete. Run 'terraform plan' to verify. ==="
