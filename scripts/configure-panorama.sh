#!/usr/bin/env bash
###############################################################################
# configure-panorama.sh — Phase 2a: Panorama Configuration (automated)
#
# Manages Bastion tunnel automatically, runs Phase 2 Terraform.
#
# Usage:
#   bash scripts/configure-panorama.sh
#
# Requirements:
#   - Phase 1a completed (Panorama VM running)
#   - az CLI logged in
#   - phase2-panorama-config/terraform.tfvars filled in
#
# Result:
#   - Panorama configured (hostname, serial, license, vm-auth-key,
#     Template Stack, Device Group, interfaces, zones, routes, NAT, security)
#   - panorama_vm_auth_key.auto.tfvars created in project root
#     (auto-loaded by Phase 1b)
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PHASE2_DIR="$ROOT_DIR/phase2-panorama-config"
TUNNEL_PID=""
LOCAL_PORT=44300

cleanup() {
  echo ""
  echo "[*] Closing Bastion tunnel..."
  if [ -n "$TUNNEL_PID" ]; then
    # Kill process group (az + Python subprocesses)
    kill -- -"$TUNNEL_PID" 2>/dev/null || kill "$TUNNEL_PID" 2>/dev/null || true
    sleep 1
    # Force kill if still alive
    kill -9 "$TUNNEL_PID" 2>/dev/null || true
    wait "$TUNNEL_PID" 2>/dev/null || true
  fi
  # Ensure port is freed (az bastion may leave orphan listeners)
  lsof -ti:"$LOCAL_PORT" 2>/dev/null | xargs kill -9 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "============================================================"
echo "  Phase 2a: Panorama Configuration"
echo "============================================================"
echo ""

# Check prerequisites
if [ ! -f "$PHASE2_DIR/terraform.tfvars" ]; then
  echo "[ERROR] Missing file: phase2-panorama-config/terraform.tfvars"
  echo "       cp phase2-panorama-config/terraform.tfvars.example phase2-panorama-config/terraform.tfvars"
  echo "       Fill in: panorama_password, panorama_serial_number, external_lb_public_ip"
  exit 1
fi

# Get Panorama VM ID and External LB IP from Terraform output
echo "[1/4] Fetching infrastructure info from Terraform output..."
cd "$ROOT_DIR"
PANORAMA_ID=$(terraform output -raw panorama_vm_id 2>/dev/null || true)
if [ -z "$PANORAMA_ID" ]; then
  echo "[ERROR] Cannot fetch panorama_vm_id. Is Phase 1a completed?"
  exit 1
fi
echo "       VM ID: $PANORAMA_ID"

# Auto-populate external_lb_public_ip if still REPLACE_ME
ELB_IP=$(terraform output -raw external_lb_public_ip 2>/dev/null || true)
if [ -n "$ELB_IP" ]; then
  echo "       External LB IP: $ELB_IP"
  if grep -q 'external_lb_public_ip.*REPLACE_ME' "$PHASE2_DIR/terraform.tfvars" 2>/dev/null; then
    echo "       [AUTO] Injecting external_lb_public_ip into phase2 terraform.tfvars..."
    sed -i '' "s|external_lb_public_ip.*=.*\"REPLACE_ME\"|external_lb_public_ip = \"$ELB_IP\"|" "$PHASE2_DIR/terraform.tfvars"
    echo "       [OK] external_lb_public_ip = \"$ELB_IP\""
  fi
else
  echo "       [WARN] Cannot fetch external_lb_public_ip. Make sure it's set in phase2 terraform.tfvars."
fi

# Start Bastion tunnel
echo "[2/4] Starting Bastion tunnel (port $LOCAL_PORT -> Panorama:443)..."
az network bastion tunnel \
  --name bastion-management \
  --resource-group rg-transit-hub \
  --target-resource-id "$PANORAMA_ID" \
  --resource-port 443 \
  --port "$LOCAL_PORT" &>/dev/null &
TUNNEL_PID=$!
echo "       Tunnel PID: $TUNNEL_PID"

# Wait for tunnel to be ready
echo "       Waiting for tunnel..."
sleep 10
for i in $(seq 1 12); do
  if curl -sk --max-time 3 -o /dev/null "https://127.0.0.1:$LOCAL_PORT/php/login.php" 2>/dev/null; then
    echo "       Tunnel ready!"
    break
  fi
  if [ "$i" -eq 12 ]; then
    echo "[ERROR] Tunnel not responding after 60s. Check Bastion and Panorama VM."
    exit 1
  fi
  sleep 5
done

# Run Phase 2 Terraform
echo "[3/4] Running Phase 2 Terraform..."
echo ""
cd "$PHASE2_DIR"
terraform init -input=false -no-color 2>&1 | tail -5
echo ""
terraform apply -auto-approve -input=false

# Verify output
echo ""
echo "[4/4] Verification..."
if [ -f "$ROOT_DIR/panorama_vm_auth_key.auto.tfvars" ]; then
  echo "  [OK] panorama_vm_auth_key.auto.tfvars created"
  echo "       Phase 1b automatically gets vm-auth-key."
else
  echo "  [WARN] panorama_vm_auth_key.auto.tfvars was NOT created."
  echo "         Check Phase 2 output above."
fi

echo ""
echo "============================================================"
echo "  Phase 2a COMPLETED"
echo ""
echo "  Next step — Phase 1b (deploy firewalls):"
echo "    cd $ROOT_DIR"
echo "    terraform apply \\"
echo "      -target=module.bootstrap \\"
echo "      -target=module.loadbalancer -target=module.firewall \\"
echo "      -target=module.routing -target=module.frontdoor -target=module.app1_app"
echo "============================================================"
