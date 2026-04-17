#!/usr/bin/env bash
###############################################################################
# scripts/fix-drift.sh
# Naprawa rozbieżności Terraform State (state drift)
#
# KIEDY URUCHAMIAĆ:
#   Gdy terraform apply zwraca błąd:
#   "A resource with the ID ... already exists - needs to be imported"
#
# WYMAGANIA:
#   - az CLI zalogowane: az login
#   - terraform init wykonany w katalogu głównym projektu
#   - Uruchom z katalogu głównego projektu (azure_ha_project/)
#
# UŻYCIE:
#   chmod +x scripts/fix-drift.sh
#   ./scripts/fix-drift.sh
#
# Co robi ten skrypt:
#   1. Importuje azurerm_virtual_machine_extension "dc_promote" do stanu TF
#      (Extension istnieje w Azure bo DC był już promowany, ale TF tego nie wie)
#   2. Usuwa stare azurerm_marketplace_agreement ze stanu (jeśli istnieją)
#      Kod zmieniony na null_resource – stare zasoby w state będą konfliktować
###############################################################################

set -euo pipefail

# ─── Kolory dla czytelności ──────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# ─── Pobierz Subscription ID ─────────────────────────────────────────────────
info "Pobieranie Subscription ID z aktywnej sesji az..."
SUB_ID=$(az account show --query id -o tsv 2>/dev/null) || {
  error "Nie można pobrać Subscription ID. Upewnij się że jesteś zalogowany: az login"
  exit 1
}
info "Subscription ID: ${SUB_ID}"

# Możesz też podać manualnie:
# SUB_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

echo ""
info "======================================================"
info " KROK 1: Usunięcie starych azurerm_marketplace_agreement ze stanu"
info "======================================================"
info "(Kod zmieniony na null_resource – stary resource type powoduje konflikt)"
echo ""

# Usuń ze stanu jeśli istnieją (nie rzuca błędu jeśli nie ma)
AGREEMENTS=(
  "module.firewall.azurerm_marketplace_agreement.panos_byol"
  "module.panorama.azurerm_marketplace_agreement.panorama"
)

for agreement in "${AGREEMENTS[@]}"; do
  if terraform state list 2>/dev/null | grep -q "^${agreement}$"; then
    warn "Usuwam ze stanu: ${agreement}"
    terraform state rm "${agreement}"
    info "Usunięto: ${agreement}"
  else
    info "Nie ma w stanie (OK): ${agreement}"
  fi
done

echo ""
info "======================================================"
info " KROK 2: Import dc_promote extension do stanu"
info "======================================================"
info "(Extension istnieje w Azure, DC jest już promowany)"
echo ""

DC_EXT_ID="/subscriptions/${SUB_ID}/resourceGroups/rg-spoke2-dc/providers/Microsoft.Compute/virtualMachines/vm-spoke2-dc/extensions/promote-to-dc"
DC_EXT_STATE="module.spoke2_dc.azurerm_virtual_machine_extension.dc_promote"

# Sprawdź czy extension istnieje w Azure
if az vm extension show \
    --resource-group rg-spoke2-dc \
    --vm-name vm-spoke2-dc \
    --name promote-to-dc \
    --query "provisioningState" -o tsv 2>/dev/null | grep -q "Succeeded"; then

  # Sprawdź czy już jest w stanie
  if terraform state list 2>/dev/null | grep -q "^${DC_EXT_STATE}$"; then
    info "dc_promote już jest w stanie Terraform – nic do zrobienia"
  else
    info "Importuję dc_promote extension do stanu Terraform..."
    terraform import "${DC_EXT_STATE}" "${DC_EXT_ID}"
    info "Import zakończony pomyślnie!"
  fi
else
  warn "Extension promote-to-dc nie istnieje w Azure lub nie jest w stanie Succeeded."
  warn "Pomiń ten krok lub sprawdź portal: Portal → vm-spoke2-dc → Extensions"
fi

echo ""
info "======================================================"
info " KROK 3: Weryfikacja stanu"
info "======================================================"
echo ""
terraform state list | grep -E "(spoke2_dc|marketplace|panorama_terms|panos_terms)" || true

echo ""
info "======================================================"
info " GOTOWE! Możesz teraz ponowić:"
info "   terraform plan -out=tfplan && terraform apply tfplan"
info "======================================================"
