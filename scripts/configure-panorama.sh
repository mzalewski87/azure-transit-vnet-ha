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

# Loud warning if panorama_serial_number is empty — Step 3 (license activation)
# is gated by `count = var.panorama_serial_number != "" ? 1 : 0` and would
# otherwise be silently skipped, leaving Panorama unlicensed.
SERIAL_LINE=$(grep -E '^\s*panorama_serial_number\s*=' "$PHASE2_DIR/terraform.tfvars" | head -1)
SERIAL_VALUE=$(echo "$SERIAL_LINE" | sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/')
if [ -z "$SERIAL_VALUE" ]; then
  echo ""
  echo "[WARN] panorama_serial_number is empty in $PHASE2_DIR/terraform.tfvars"
  echo "       => Step 3 (set serial + commit + 'request license fetch') will be SKIPPED."
  echo "       => Panorama will run UNLICENSED (no log retention, no SLS, etc.)."
  echo "       => Fix: set panorama_serial_number = \"007300XXXXXXX\" (from CSP Portal)"
  echo "          and re-run this script. The licensing step is idempotent."
  echo ""
  read -r -p "Continue anyway? [y/N] " ANSWER
  if [ "$ANSWER" != "y" ] && [ "$ANSWER" != "Y" ]; then
    echo "Aborted. Edit terraform.tfvars and re-run."
    exit 1
  fi
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

# ALWAYS sync external_lb_public_ip with current terraform output.
#
# Azure dynamically allocates a NEW public IP for the External LB on every
# fresh deploy (after destroy + apply). If the phase2 tfvars still carries
# the old IP (from a previous iteration), the DNAT rule and the
# Allow-Inbound-Web security rule on the FW will be configured against the
# wrong destination — health probes will be 100% Up but real client traffic
# from the Internet (with dst = current ELB Public IP, kept by floating IP)
# will silently drop because no NAT/security rule matches it. Symptom: ELB
# curl times out, AFD returns 504, but Backend Health = 100% and FW packet
# capture shows happy probe traffic.
#
# Earlier behaviour only auto-injected when the value was literally
# REPLACE_ME — that left stale IPs untouched and caused exactly the bug
# above on a redeploy.
ELB_IP=$(terraform output -raw external_lb_public_ip 2>/dev/null || true)
if [ -n "$ELB_IP" ]; then
  echo "       External LB IP (from terraform output): $ELB_IP"
  CURRENT_VAL=$(grep -E '^\s*external_lb_public_ip\s*=' "$PHASE2_DIR/terraform.tfvars" 2>/dev/null \
    | head -1 | sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/')
  if [ "$CURRENT_VAL" != "$ELB_IP" ]; then
    echo "       [AUTO] external_lb_public_ip in phase2 tfvars (was: ${CURRENT_VAL:-empty}) does not match — updating to $ELB_IP"
    sed -i '' "s|external_lb_public_ip[[:space:]]*=[[:space:]]*\"[^\"]*\"|external_lb_public_ip = \"$ELB_IP\"|" "$PHASE2_DIR/terraform.tfvars"
    echo "       [OK] phase2 terraform.tfvars updated"
  else
    echo "       [OK] phase2 terraform.tfvars already has the correct value"
  fi
else
  echo "       [WARN] Cannot fetch external_lb_public_ip from terraform output."
  echo "              Make sure it's set in phase2 terraform.tfvars manually."
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
#
# parallelism=2 (default is 10): empirically the safe ceiling for panos via
# Bastion tunnel. Higher values cause Panorama to return "Session timed out"
# on a random resource mid-apply — multiple parallel API calls through the
# single tunnel saturate Panorama's per-admin session pool, and any
# validation error in one parallel call (e.g. an invalid App-ID name) can
# cascade into session resets on the others. 2 keeps total apply time
# reasonable (~5-7 min) while being reliable.
echo "[3/4] Running Phase 2 Terraform (parallelism=2)..."
echo ""
cd "$PHASE2_DIR"
terraform init -input=false -no-color 2>&1 | tail -5
echo ""
terraform apply -auto-approve -input=false -parallelism=2

# Verify output and auto-inject vm-auth-key into terraform.tfvars
echo ""
echo "[4/4] Verification..."
if [ -f "$ROOT_DIR/panorama_vm_auth_key.txt" ]; then
  VM_KEY=$(cat "$ROOT_DIR/panorama_vm_auth_key.txt" | tr -d '[:space:]')
  echo "  [OK] vm-auth-key generated: ${VM_KEY:0:20}..."

  # Auto-inject into terraform.tfvars (replace empty or existing value)
  if [ -f "$ROOT_DIR/terraform.tfvars" ] && [ -n "$VM_KEY" ]; then
    if grep -q 'panorama_vm_auth_key' "$ROOT_DIR/terraform.tfvars"; then
      sed -i '' "s|panorama_vm_auth_key[[:space:]]*=[[:space:]]*\"[^\"]*\"|panorama_vm_auth_key = \"$VM_KEY\"|" "$ROOT_DIR/terraform.tfvars"
      echo "  [OK] panorama_vm_auth_key updated in terraform.tfvars"
    else
      echo "" >> "$ROOT_DIR/terraform.tfvars"
      echo "panorama_vm_auth_key = \"$VM_KEY\"" >> "$ROOT_DIR/terraform.tfvars"
      echo "  [OK] panorama_vm_auth_key added to terraform.tfvars"
    fi
  fi

  echo "       Phase 1b will use this key automatically."
else
  echo "  [WARN] panorama_vm_auth_key.txt was NOT created."
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
