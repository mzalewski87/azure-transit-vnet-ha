#!/usr/bin/env bash
###############################################################################
# configure-panorama.sh — Phase 2a: Konfiguracja Panoramy (automatyczna)
#
# Zarządza Bastion tunnel automatycznie, uruchamia Phase 2 Terraform.
#
# Użycie:
#   bash scripts/configure-panorama.sh
#
# Wymagania:
#   - Phase 1a zakończona (Panorama VM uruchomiona)
#   - az CLI zalogowany
#   - phase2-panorama-config/terraform.tfvars uzupełniony
#
# Efekt:
#   - Panorama skonfigurowana (hostname, serial, licencja, vm-auth-key,
#     Template Stack, Device Group, interfejsy, zony, trasy, NAT, security)
#   - panorama_vm_auth_key.auto.tfvars utworzony w katalogu root
#     (automatycznie wczytywany przez Phase 1b)
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PHASE2_DIR="$ROOT_DIR/phase2-panorama-config"
TUNNEL_PID=""
LOCAL_PORT=44300

cleanup() {
  if [ -n "$TUNNEL_PID" ] && kill -0 "$TUNNEL_PID" 2>/dev/null; then
    echo ""
    echo "[*] Zamykanie Bastion tunnel (PID $TUNNEL_PID)..."
    kill "$TUNNEL_PID" 2>/dev/null || true
    wait "$TUNNEL_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

echo "============================================================"
echo "  Phase 2a: Konfiguracja Panoramy"
echo "============================================================"
echo ""

# Check prerequisites
if [ ! -f "$PHASE2_DIR/terraform.tfvars" ]; then
  echo "[BLAD] Brak pliku: phase2-panorama-config/terraform.tfvars"
  echo "       cp phase2-panorama-config/terraform.tfvars.example phase2-panorama-config/terraform.tfvars"
  echo "       Uzupelnij: panorama_password, panorama_serial_number, external_lb_public_ip"
  exit 1
fi

# Get Panorama VM ID from Terraform output
echo "[1/4] Pobieranie Panorama VM ID z Terraform output..."
cd "$ROOT_DIR"
PANORAMA_ID=$(terraform output -raw panorama_vm_id 2>/dev/null || true)
if [ -z "$PANORAMA_ID" ]; then
  echo "[BLAD] Nie mozna pobrac panorama_vm_id. Czy Phase 1a zostala zakonczona?"
  exit 1
fi
echo "       VM ID: $PANORAMA_ID"

# Start Bastion tunnel
echo "[2/4] Uruchamianie Bastion tunnel (port $LOCAL_PORT -> Panorama:443)..."
az network bastion tunnel \
  --name bastion-management \
  --resource-group rg-transit-hub \
  --target-resource-id "$PANORAMA_ID" \
  --resource-port 443 \
  --port "$LOCAL_PORT" &>/dev/null &
TUNNEL_PID=$!
echo "       Tunnel PID: $TUNNEL_PID"

# Wait for tunnel to be ready
echo "       Czekam na tunnel..."
sleep 10
for i in $(seq 1 12); do
  if curl -sk --max-time 3 -o /dev/null "https://127.0.0.1:$LOCAL_PORT/php/login.php" 2>/dev/null; then
    echo "       Tunnel gotowy!"
    break
  fi
  if [ "$i" -eq 12 ]; then
    echo "[BLAD] Tunnel nie odpowiada po 60s. Sprawdz Bastion i Panorama VM."
    exit 1
  fi
  sleep 5
done

# Run Phase 2 Terraform
echo "[3/4] Uruchamianie Phase 2 Terraform..."
echo ""
cd "$PHASE2_DIR"
terraform init -input=false -no-color 2>&1 | tail -5
echo ""
terraform apply -auto-approve -input=false

# Verify output
echo ""
echo "[4/4] Weryfikacja..."
if [ -f "$ROOT_DIR/panorama_vm_auth_key.auto.tfvars" ]; then
  echo "  [OK] panorama_vm_auth_key.auto.tfvars utworzony"
  echo "       Phase 1b automatycznie pobierze vm-auth-key."
else
  echo "  [WARN] panorama_vm_auth_key.auto.tfvars NIE zostal utworzony."
  echo "         Sprawdz output Phase 2 powyzej."
fi

echo ""
echo "============================================================"
echo "  Phase 2a ZAKONCZONA"
echo ""
echo "  Nastepny krok — Phase 1b (deploy firewalli):"
echo "    cd $ROOT_DIR"
echo "    terraform apply \\"
echo "      -target=module.bootstrap \\"
echo "      -target=module.loadbalancer -target=module.firewall \\"
echo "      -target=module.routing -target=module.frontdoor -target=module.app1_app"
echo "============================================================"
