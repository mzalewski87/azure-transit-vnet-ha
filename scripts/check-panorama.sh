#!/usr/bin/env bash
###############################################################################
# scripts/check-panorama.sh
# Czeka na gotowość Panoramy (HTTPS + sprawdza odpowiedź GUI)
#
# UŻYCIE:
#   chmod +x scripts/check-panorama.sh
#   ./scripts/check-panorama.sh
#
# LUB z konkretnym IP:
#   PANORAMA_IP="1.2.3.4" ./scripts/check-panorama.sh
#
# Skrypt odpyta co 60 sekund przez maksymalnie 30 minut.
# Gdy Panorama odpowie – wyświetla instrukcję generowania VM Auth Key.
###############################################################################

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

MAX_WAIT_MIN=30
INTERVAL_SEC=60
MAX_ATTEMPTS=$((MAX_WAIT_MIN * 60 / INTERVAL_SEC))

# Pobierz IP Panoramy
if [[ -z "${PANORAMA_IP:-}" ]]; then
  PANORAMA_IP=$(terraform output -raw panorama_public_ip 2>/dev/null) || {
    echo "Nie można pobrać panorama_public_ip z terraform output."
    echo "Użyj: PANORAMA_IP='x.x.x.x' ./scripts/check-panorama.sh"
    exit 1
  }
fi

echo -e "${BLUE}══════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Czekam na gotowość Panoramy: https://$PANORAMA_IP${NC}"
echo -e "${BLUE}  Maks. czas oczekiwania: ${MAX_WAIT_MIN} min${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════${NC}"
echo ""

attempt=0
while [ $attempt -lt $MAX_ATTEMPTS ]; do
  attempt=$((attempt + 1))
  elapsed_min=$(( (attempt - 1) * INTERVAL_SEC / 60 ))

  if curl -sk --connect-timeout 8 --max-time 15 "https://$PANORAMA_IP/php/login.php" -o /dev/null 2>/dev/null; then
    echo -e "\n${GREEN}✅ Panorama HTTPS dostępna! (po ~${elapsed_min} min)${NC}\n"

    echo -e "${YELLOW}══════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  NASTĘPNE KROKI – wykonaj w przeglądarce:${NC}"
    echo -e "${YELLOW}══════════════════════════════════════════════════${NC}"
    echo ""
    echo "  1. Otwórz: https://$PANORAMA_IP"
    echo "     Login: panadmin  |  Hasło: z terraform.tfvars"
    echo ""
    echo "  2. AKTYWUJ LICENCJĘ (jeśli nie aktywowała się z init-cfg):"
    echo "     Panorama → Licenses → Activate feature using auth code"
    echo "     → Wpisz panorama_auth_code z terraform.tfvars"
    echo ""
    echo "  3. WYGENERUJ VM AUTH KEY:"
    echo "     Panorama → Device Registration Auth Key → Generate"
    echo "     → Ważność: 8760 hours (1 rok)"
    echo "     → Skopiuj klucz"
    echo ""
    echo "  4. WKLEJ KLUCZ do terraform.tfvars:"
    echo "     panorama_vm_auth_key = \"SKOPIOWANY-KLUCZ\""
    echo ""
    echo "  5. URUCHOM Phase 1b:"
    echo "     terraform apply -target=module.bootstrap"
    echo "     terraform apply \\"
    echo "       -target=module.loadbalancer \\"
    echo "       -target=module.firewall \\"
    echo "       -target=module.routing \\"
    echo "       -target=module.frontdoor \\"
    echo "       -target=module.spoke1_app \\"
    echo "       -target=module.spoke2_dc"
    echo ""
    exit 0
  fi

  echo -e "${YELLOW}[${elapsed_min} min]${NC} Panorama nie gotowa. Następna próba za ${INTERVAL_SEC}s..."
  sleep $INTERVAL_SEC
done

echo ""
echo "❌ Panorama nie odpowiedziała po ${MAX_WAIT_MIN} minutach."
echo "   Sprawdź w Azure Portal czy VM jest uruchomiona:"
echo "   Portal → rg-transit-hub → vm-panorama → Status"
echo ""
echo "   Ręczne sprawdzenie:"
echo "   curl -sk --connect-timeout 10 https://$PANORAMA_IP/php/login.php -v"
exit 1
