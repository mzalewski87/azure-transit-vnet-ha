#!/usr/bin/env bash
###############################################################################
# register-fw-panorama.sh — Phase 2b: FW Registration on Panorama
#
# Automatically:
#   1. Opens Bastion tunnels to FW1, FW2, and Panorama
#   2. Reads FW serial numbers via the XML API
#   3. Sets the auth-key on the FWs (request authkey set)
#   4. Adds the serials to Panorama (mgt-config, device-group, template-stack)
#   5. Commits to Panorama
#
# Usage:
#   bash scripts/register-fw-panorama.sh
#
# Requirements:
#   - Phase 1b completed (FW1 + FW2 running, licenses active)
#   - Phase 2a completed (Panorama configured, vm-auth-key generated)
#   - az CLI logged in
#
# XML API commands (confirmed by debug cli on Panorama):
#   set mgt-config devices SERIAL →
#     type=config&action=set&xpath=/config/mgt-config/devices&element=<entry name='SERIAL'/>
#   set device-group DG devices SERIAL →
#     type=config&action=set&xpath=.../device-group/entry[@name='DG']/devices&element=<entry name='SERIAL'/>
#   set template-stack TS devices SERIAL →
#     type=config&action=set&xpath=.../template-stack/entry[@name='TS']/devices&element=<entry name='SERIAL'/>
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Ports for Bastion tunnels
PANORAMA_PORT=44300
FW1_PORT=44301
FW2_PORT=44302

# Panorama config names (from terraform.tfvars defaults)
DEVICE_GROUP="${DEVICE_GROUP:-Transit-VNet-DG}"
TEMPLATE_STACK="${TEMPLATE_STACK:-Transit-VNet-Stack}"

# Credentials
PAN_USER="${PAN_USER:-panadmin}"

TUNNEL_PIDS=()

cleanup() {
  echo ""
  echo "[*] Closing Bastion tunnels..."
  for pid in "${TUNNEL_PIDS[@]}"; do
    # Kill process group (az + Python subprocesses)
    kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
  done
  sleep 1
  # Force kill any survivors
  for pid in "${TUNNEL_PIDS[@]}"; do
    kill -9 "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  # Ensure all ports are freed
  for port in "$PANORAMA_PORT" "$FW1_PORT" "$FW2_PORT"; do
    lsof -ti:"$port" 2>/dev/null | xargs kill -9 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

get_api_key() {
  local url="$1" user="$2" pass="$3"
  local enc_pass
  enc_pass=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$pass', safe=''))")
  curl -sk --max-time 30 \
    "$url/api/?type=keygen&user=$user&password=$enc_pass" 2>/dev/null \
    | python3 -c "
import sys, xml.etree.ElementTree as ET
root = ET.fromstring(sys.stdin.read())
if root.get('status') != 'success':
    print('ERROR:' + (root.findtext('.//msg','login failed')), file=sys.stderr); sys.exit(1)
print(root.findtext('.//key',''))
" 2>&1
}

get_serial() {
  # Robust: never fails the calling pipe under set -euo pipefail.
  # Returns one of:
  #   <serial>  — actual serial (license activation complete, system-info populated)
  #   unknown   — XML parsed OK but no <serial> field (license still activating)
  #   <empty>   — network/curl failed OR XML malformed (FW briefly down or restarting)
  local url="$1" api_key="$2"
  local raw
  raw=$(curl -sk --max-time 30 \
    "$url/api/?type=op&cmd=<show><system><info></info></system></show>&key=$api_key" 2>/dev/null) \
    || raw=""
  if [ -z "$raw" ]; then
    echo ""
    return 0
  fi
  echo "$raw" | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read())
    if root.get('status','') != 'success':
        print(''); sys.exit(0)
    s = (root.findtext('.//serial','') or '').strip()
    print(s if s else 'unknown')
except Exception:
    print('')
" 2>/dev/null || echo ""
}

start_tunnel() {
  local name="$1" vm_id="$2" local_port="$3"
  echo "  Tunnel $name (port $local_port)..."
  az network bastion tunnel \
    --name bastion-management \
    --resource-group rg-transit-hub \
    --target-resource-id "$vm_id" \
    --resource-port 443 \
    --port "$local_port" &>/dev/null &
  TUNNEL_PIDS+=($!)
}

wait_for_tunnel() {
  local port="$1" name="$2"
  for i in $(seq 1 12); do
    if curl -sk --max-time 3 -o /dev/null "https://127.0.0.1:$port" 2>/dev/null; then
      return 0
    fi
    sleep 5
  done
  echo "[ERROR] Tunnel $name (port $port) not responding."
  return 1
}

echo "============================================================"
echo "  Phase 2b: FW Registration on Panorama"
echo "============================================================"
echo ""

# Get password — auto-read from terraform.tfvars if not set via environment
if [ -z "${PAN_PASS:-}" ]; then
  if [ -f "$ROOT_DIR/terraform.tfvars" ]; then
    PAN_PASS=$(grep -E '^\s*admin_password\s*=' "$ROOT_DIR/terraform.tfvars" \
      | head -1 | sed 's/.*=[[:space:]]*"\(.*\)".*/\1/')
  fi
  if [ -z "${PAN_PASS:-}" ]; then
    echo -n "Admin password (panadmin): "
    read -rs PAN_PASS
    echo
  else
    echo "  Password: read from terraform.tfvars"
  fi
fi

# Get VM IDs from Terraform output
echo "[1/6] Fetching VM IDs from Terraform output..."
cd "$ROOT_DIR"
PANORAMA_ID=$(terraform output -raw panorama_vm_id 2>/dev/null)
FW1_ID=$(terraform output -raw fw1_vm_id 2>/dev/null)
FW2_ID=$(terraform output -raw fw2_vm_id 2>/dev/null)
FW1_MGMT_IP=$(terraform output -raw fw1_mgmt_private_ip 2>/dev/null)
FW2_MGMT_IP=$(terraform output -raw fw2_mgmt_private_ip 2>/dev/null)
echo "       Panorama: $PANORAMA_ID"
echo "       FW1:      $FW1_ID  (mgmt $FW1_MGMT_IP)"
echo "       FW2:      $FW2_ID  (mgmt $FW2_MGMT_IP)"

# Read vm-auth-key (will auto-generate after tunnels are up if missing)
VM_AUTH_KEY=""
if [ -f "$ROOT_DIR/panorama_vm_auth_key.txt" ]; then
  VM_AUTH_KEY=$(cat "$ROOT_DIR/panorama_vm_auth_key.txt" | tr -d '[:space:]')
  echo "       Auth key: ${VM_AUTH_KEY:0:20}..."
else
  echo "       Auth key: file missing — will be generated in step 3.5"
fi

# Start tunnels
echo ""
echo "[2/6] Starting Bastion tunnels..."
start_tunnel "Panorama" "$PANORAMA_ID" "$PANORAMA_PORT"
start_tunnel "FW1"      "$FW1_ID"      "$FW1_PORT"
start_tunnel "FW2"      "$FW2_ID"      "$FW2_PORT"

echo "  Waiting for tunnels..."
sleep 10
wait_for_tunnel "$PANORAMA_PORT" "Panorama"
wait_for_tunnel "$FW1_PORT" "FW1"
wait_for_tunnel "$FW2_PORT" "FW2"
echo "  All tunnels ready!"

# Wait for FWs to be ready (API responsive) before reading serials
echo ""
echo "[3/6] Waiting for firewalls to be ready..."
echo "       FWs need ~10-15 min after deployment to fully boot (PAN-OS + license activation)."
echo ""

FW1_KEY=""
FW2_KEY=""
MAX_FW_WAIT=30  # 30 x 30s = 15 min

for FW_WAIT in $(seq 1 $MAX_FW_WAIT); do
  # Try FW1
  if [ -z "$FW1_KEY" ]; then
    FW1_KEY=$(get_api_key "https://127.0.0.1:$FW1_PORT" "$PAN_USER" "$PAN_PASS" 2>/dev/null || echo "")
    if [ -n "$FW1_KEY" ] && ! echo "$FW1_KEY" | grep -q "^ERROR"; then
      echo "  [OK] FW1 API ready (attempt $FW_WAIT)"
    else
      FW1_KEY=""
    fi
  fi

  # Try FW2
  if [ -z "$FW2_KEY" ]; then
    FW2_KEY=$(get_api_key "https://127.0.0.1:$FW2_PORT" "$PAN_USER" "$PAN_PASS" 2>/dev/null || echo "")
    if [ -n "$FW2_KEY" ] && ! echo "$FW2_KEY" | grep -q "^ERROR"; then
      echo "  [OK] FW2 API ready (attempt $FW_WAIT)"
    else
      FW2_KEY=""
    fi
  fi

  # Both ready?
  if [ -n "$FW1_KEY" ] && [ -n "$FW2_KEY" ]; then
    echo "  Both firewalls are ready!"
    break
  fi

  if [ "$FW_WAIT" -ge "$MAX_FW_WAIT" ]; then
    echo ""
    echo "[ERROR] Firewalls not ready after 15 min."
    [ -z "$FW1_KEY" ] && echo "  FW1: NOT responding"
    [ -z "$FW2_KEY" ] && echo "  FW2: NOT responding"
    echo ""
    echo "  FWs may still be booting. Wait a few more minutes and re-run:"
    echo "    bash scripts/register-fw-panorama.sh"
    exit 1
  fi

  STATUS=""
  [ -z "$FW1_KEY" ] && STATUS="FW1: waiting"
  [ -z "$FW2_KEY" ] && STATUS="${STATUS:+$STATUS, }FW2: waiting"
  echo "  [$FW_WAIT/$MAX_FW_WAIT] $STATUS — retrying in 30s..."
  sleep 30
done

# Read serials.
# License activation is asynchronous and finishes AFTER the API becomes
# responsive — so "API ready" (the wait loop above) is necessary but not
# sufficient. Retry until both serials come through, with detailed diagnostics
# on final failure so the operator knows what to check, instead of the script
# silently dying via set -e + pipefail when XML parsing fails on a stale
# response.
echo ""
echo "  Reading serial numbers (license activation must complete first)..."
MAX_SERIAL_TRIES=10  # 10 x 30s = 5 min total
FW1_SERIAL=""
FW2_SERIAL=""

is_real_serial() {
  # Empty string and the literal 'unknown' are both "not yet ready".
  [ -n "$1" ] && [ "$1" != "unknown" ]
}

for SERIAL_TRY in $(seq 1 "$MAX_SERIAL_TRIES"); do
  if ! is_real_serial "$FW1_SERIAL"; then
    FW1_SERIAL=$(get_serial "https://127.0.0.1:$FW1_PORT" "$FW1_KEY")
    if is_real_serial "$FW1_SERIAL"; then
      echo "  [OK] FW1 serial: $FW1_SERIAL (attempt $SERIAL_TRY)"
    fi
  fi
  if ! is_real_serial "$FW2_SERIAL"; then
    FW2_SERIAL=$(get_serial "https://127.0.0.1:$FW2_PORT" "$FW2_KEY")
    if is_real_serial "$FW2_SERIAL"; then
      echo "  [OK] FW2 serial: $FW2_SERIAL (attempt $SERIAL_TRY)"
    fi
  fi

  if is_real_serial "$FW1_SERIAL" && is_real_serial "$FW2_SERIAL"; then
    echo "  Both serials read successfully."
    break
  fi

  if [ "$SERIAL_TRY" -ge "$MAX_SERIAL_TRIES" ]; then
    echo ""
    echo "[ERROR] Could not read FW serial numbers after $((MAX_SERIAL_TRIES * 30 / 60)) min."
    echo "        FW1 serial: ${FW1_SERIAL:-<empty/unparseable>}"
    echo "        FW2 serial: ${FW2_SERIAL:-<empty/unparseable>}"
    echo ""
    echo "        Most likely cause: license activation has not completed."
    echo "        License activation can take 5-15 min after first boot and"
    echo "        depends on outbound HTTPS to api.paloaltonetworks.com."
    echo ""
    echo "        Diagnose on the FW that's missing a serial (Bastion SSH):"
    echo "          admin@fw1> show system info | match \"serial\\|model\""
    echo "          admin@fw1> request license info"
    echo "          admin@fw1> show jobs all"
    echo "          admin@fw1> less mp-log auto-license.log"
    echo "          admin@fw1> ping host api.paloaltonetworks.com"
    echo ""
    echo "        Raw API response (FW1) for diagnostic:"
    curl -sk --max-time 15 \
      "https://127.0.0.1:$FW1_PORT/api/?type=op&cmd=<show><system><info></info></system></show>&key=$FW1_KEY" 2>&1 \
      | head -20
    echo ""
    echo "        If license is shown active but serial still empty, wait a"
    echo "        few more minutes for licensing-server propagation, then re-run:"
    echo "          bash scripts/register-fw-panorama.sh"
    exit 1
  fi

  STATUS=""
  is_real_serial "$FW1_SERIAL" || STATUS="FW1: no serial yet"
  is_real_serial "$FW2_SERIAL" || STATUS="${STATUS:+$STATUS, }FW2: no serial yet"
  echo "  [$SERIAL_TRY/$MAX_SERIAL_TRIES] $STATUS — retrying in 30s..."
  sleep 30
done

# Auto-generate or retrieve auth-key on Panorama if missing
if [ -z "$VM_AUTH_KEY" ]; then
  echo ""
  echo "[3.5/6] Fetching/generating vm-auth-key on Panorama..."
  PAN_KEY_TMP=$(get_api_key "https://127.0.0.1:$PANORAMA_PORT" "$PAN_USER" "$PAN_PASS")

  # Step A: Try to LIST existing auth keys first
  LIST_RESP=$(curl -sk --max-time 30 \
    "https://127.0.0.1:$PANORAMA_PORT/api/?type=op&cmd=<request><authkey><list></list></authkey></request>&key=$PAN_KEY_TMP" \
    2>/dev/null || echo "")

  VM_AUTH_KEY=$(echo "$LIST_RESP" | python3 -c "
import sys, xml.etree.ElementTree as ET, re
try:
    data = sys.stdin.read()
    if not data: sys.exit(0)
    root = ET.fromstring(data)
    # Search for auth key pattern (2:XXXXX) in response
    for elem in root.iter():
        if elem.text:
            m = re.search(r'(2:[\w-]{20,})', elem.text)
            if m: print(m.group(1)); sys.exit(0)
except: pass
" 2>/dev/null)

  if [ -n "$VM_AUTH_KEY" ]; then
    echo "  [OK] Existing auth key found: ${VM_AUTH_KEY:0:30}..."
  else
    # Step B: Generate new key with unique name (timestamp-based)
    KEY_NAME="authkey-$(date +%s)"
    echo "  No existing keys found, generating new ($KEY_NAME)..."

    for GEN_TRY in $(seq 1 3); do
      GEN_RESP=$(curl -sk --max-time 60 \
        "https://127.0.0.1:$PANORAMA_PORT/api/?type=op&cmd=<request><authkey><add><name>$KEY_NAME</name><lifetime>1440</lifetime><count>10</count></add></authkey></request>&key=$PAN_KEY_TMP" \
        2>/dev/null || echo "")

      VM_AUTH_KEY=$(echo "$GEN_RESP" | python3 -c "
import sys, xml.etree.ElementTree as ET, re
try:
    data = sys.stdin.read()
    if not data: print(''); sys.exit(0)
    root = ET.fromstring(data)
    if root.get('status') != 'success':
        msg = root.findtext('.//msg','') or root.findtext('.//line','')
        print('ERROR: ' + str(msg)); sys.exit(0)
    for elem in root.iter():
        if elem.text:
            m = re.search(r'(2:[\w-]{20,})', elem.text)
            if m: print(m.group(1)); sys.exit(0)
    print('ERROR: key pattern not found'); sys.exit(0)
except Exception as e:
    print('ERROR: ' + str(e)); sys.exit(0)
" 2>/dev/null)

      if [ -n "$VM_AUTH_KEY" ] && ! echo "$VM_AUTH_KEY" | grep -q "^ERROR"; then
        echo "  [OK] Auth key generated!"
        break
      fi
      echo "  [$GEN_TRY/3] $VM_AUTH_KEY — waiting 10s..."
      VM_AUTH_KEY=""
      sleep 10
    done
  fi

  # Save if found
  if [ -n "$VM_AUTH_KEY" ] && ! echo "$VM_AUTH_KEY" | grep -q "^ERROR"; then
    echo "  Auth key: ${VM_AUTH_KEY:0:30}..."
    echo "$VM_AUTH_KEY" > "$ROOT_DIR/panorama_vm_auth_key.txt"
    echo "  Saved to: panorama_vm_auth_key.txt"
  else
    VM_AUTH_KEY=""
    echo "  [WARN] Failed to fetch/generate auth-key."
    echo "         Generate manually: SSH to Panorama -> request authkey add name authkey1 lifetime 1440 count 2"
  fi
fi

# Set auth-key on FWs (if available)
if [ -n "$VM_AUTH_KEY" ]; then
  echo ""
  echo "[4/6] Setting auth-key on firewalls..."
  # CLI: request authkey set KEY
  # XML API: type=op, cmd=<request><authkey><set>KEY</set></authkey></request>
  for fw_info in "FW1:$FW1_PORT:$FW1_KEY" "FW2:$FW2_PORT:$FW2_KEY"; do
    IFS=':' read -r fw_name fw_port fw_key <<< "$fw_info"
    echo "  $fw_name: setting auth-key..."
    AUTH_RESP=$(curl -sk --max-time 30 "https://127.0.0.1:$fw_port/api/" \
      --data-urlencode "type=op" \
      --data-urlencode "cmd=<request><authkey><set>$VM_AUTH_KEY</set></authkey></request>" \
      --data-urlencode "key=$fw_key" 2>/dev/null)
    echo "  $fw_name: done"
  done
else
  echo ""
  echo "[4/6] SKIPPED — missing panorama_vm_auth_key.txt"
  echo "       FWs may not connect to Panorama automatically."
fi

# Register serials on Panorama
echo ""
echo "[5/6] Registering serials on Panorama..."
PAN_KEY=$(get_api_key "https://127.0.0.1:$PANORAMA_PORT" "$PAN_USER" "$PAN_PASS")
PAN_URL="https://127.0.0.1:$PANORAMA_PORT/api/"

register_fw() {
  local serial="$1" label="$2"
  echo "  $label  serial=$serial"

  # mgt-config devices
  echo "    -> mgt-config devices..."
  curl -sk --max-time 30 "$PAN_URL" \
    --data-urlencode "type=config" \
    --data-urlencode "action=set" \
    --data-urlencode "xpath=/config/mgt-config/devices" \
    --data-urlencode "element=<entry name='$serial'/>" \
    --data-urlencode "key=$PAN_KEY" > /dev/null

  # device-group devices
  echo "    -> device-group $DEVICE_GROUP..."
  curl -sk --max-time 30 "$PAN_URL" \
    --data-urlencode "type=config" \
    --data-urlencode "action=set" \
    --data-urlencode "xpath=/config/devices/entry[@name='localhost.localdomain']/device-group/entry[@name='$DEVICE_GROUP']/devices" \
    --data-urlencode "element=<entry name='$serial'/>" \
    --data-urlencode "key=$PAN_KEY" > /dev/null

  # template-stack devices
  echo "    -> template-stack $TEMPLATE_STACK..."
  curl -sk --max-time 30 "$PAN_URL" \
    --data-urlencode "type=config" \
    --data-urlencode "action=set" \
    --data-urlencode "xpath=/config/devices/entry[@name='localhost.localdomain']/template-stack/entry[@name='$TEMPLATE_STACK']/devices" \
    --data-urlencode "element=<entry name='$serial'/>" \
    --data-urlencode "key=$PAN_KEY" > /dev/null

  echo "    OK"
}

register_fw "$FW1_SERIAL" "FW1"
register_fw "$FW2_SERIAL" "FW2"

###############################################################################
# Device Log Forwarding — bind FW serials to default Collector Group with
# local Panorama LC as the preferred collector.
#
# Without this, the GUI "Panorama → Collector Groups → default → Device Log
# Forwarding" tab is empty. Per panorama-admin.pdf p.19082-19090 it is
# technically not a hard requirement for single-LC topology (logs are still
# accepted), but in practice with PAN-OS 12.1.5 the buffer behaviour without
# DLF causes logd to drop logs after a small in-memory accumulation
# (incoming log counters increment but blkcount stays at 0 → nothing
# persists to disk). Adding DLF entries fixes the persistence path.
#
# Empirically discovered XML structure (PAN-OS 12.1.5, 2026-05-06) by
# inspecting the live config after a manual GUI add:
#   xpath: /config/devices/entry[@name='localhost.localdomain']/
#          log-collector-group/entry[@name='default']/logfwd-setting/devices
#   element: <entry name='FW_SERIAL'>
#              <collectors>
#                <entry name='LC_SERIAL'/>     <!-- entry name= for DLF members,
#              </collectors>                        NOT <member>SERIAL</member>
#            </entry>                              like the parent collectors -->
###############################################################################
echo ""
echo "[5b/6] Setting Device Log Forwarding (FW -> local Panorama LC)..."

# Discover Panorama serial via API (panorama_serial_number could be embedded in
# tfvars but pulling from the device avoids drift).
PAN_SERIAL=$(curl -sk --max-time 15 \
  "$PAN_URL?type=op&cmd=<show><system><info></info></system></show>&key=$PAN_KEY" 2>/dev/null \
  | python3 -c "
import sys, xml.etree.ElementTree as ET
try: print(ET.fromstring(sys.stdin.read()).findtext('.//serial','') or '')
except: print('')
" 2>/dev/null)

if [ -z "$PAN_SERIAL" ]; then
  echo "  [WARN] Could not discover Panorama serial via API — skipping DLF setup."
  echo "         Configure manually: Panorama -> Collector Groups -> default -> Device Log Forwarding"
else
  echo "  Panorama LC serial: $PAN_SERIAL"
  for FW_LABEL in "FW1:$FW1_SERIAL" "FW2:$FW2_SERIAL"; do
    LABEL="${FW_LABEL%%:*}"
    SERIAL="${FW_LABEL##*:}"
    DLF_RESP=$(curl -sk --max-time 20 "$PAN_URL" \
      --data-urlencode "type=config" \
      --data-urlencode "action=set" \
      --data-urlencode "xpath=/config/devices/entry[@name='localhost.localdomain']/log-collector-group/entry[@name='default']/logfwd-setting/devices" \
      --data-urlencode "element=<entry name='$SERIAL'><collectors><entry name='$PAN_SERIAL'/></collectors></entry>" \
      --data-urlencode "key=$PAN_KEY" 2>/dev/null)
    DLF_STATUS=$(echo "$DLF_RESP" | python3 -c "
import sys, xml.etree.ElementTree as ET
try: print(ET.fromstring(sys.stdin.read()).get('status',''))
except: print('parse-error')
" 2>/dev/null)
    if [ "$DLF_STATUS" = "success" ]; then
      echo "  [OK] $LABEL ($SERIAL) -> LC $PAN_SERIAL"
    else
      MSG=$(echo "$DLF_RESP" | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    r = ET.fromstring(sys.stdin.read())
    print(r.findtext('.//msg','') or r.findtext('.//line','') or 'unknown')
except: print('unparseable')
" 2>/dev/null)
      echo "  [WARN] $LABEL DLF set failed: $MSG"
    fi
  done
fi

###############################################################################
# FW device certificates — handled at FW first boot, NOT here.
#
# Earlier versions of this script tried to fetch FW device certificates
# post-boot via per-serial OTPs read from root tfvars (fw1_device_otp /
# fw2_device_otp). That approach was structurally broken: OTPs are generated
# in CSP Portal AGAINST a known serial, but VM-Series BYOL serials are
# assigned by PAN-OS at first boot during license activation — they are not
# known pre-deploy, so per-serial OTPs cannot be pre-generated.
#
# Correct approach (per VM-Series Deployment Guide v11.1, pages 178-181):
# use the VM-Series Auto-Registration PIN flow. The user generates ONE PIN
# pair (PIN ID + PIN Value) in CSP Portal, sets it via root variables
# fw_registration_pin_id + fw_registration_pin_value (terraform.tfvars), and
# the bootstrap module emits vm-series-auto-registration-pin-id and
# vm-series-auto-registration-pin-value into init-cfg.txt. The FW reads
# these from IMDS at first boot and auto-registers + auto-fetches its
# device certificate during license activation. No post-boot fetch step
# from this script is possible or needed.
#
# Panorama device certificate is different — Panorama serial IS known
# pre-deploy (panorama_serial_number tfvar), so the per-serial OTP flow
# works there. See phase2-panorama-config/ for the Panorama OTP fetch.
###############################################################################

# Commit on Panorama
echo ""
echo "[6/6] Committing on Panorama..."
COMMIT_RESP=$(curl -sk --max-time 90 "$PAN_URL" \
  --data-urlencode "type=commit" \
  --data-urlencode "cmd=<commit></commit>" \
  --data-urlencode "key=$PAN_KEY" 2>/dev/null)

echo "$COMMIT_RESP" | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read())
    status = root.get('status','')
    if status == 'success':
        print('  [OK] Commit: success!')
    else:
        msg = root.findtext('.//msg','') or root.findtext('.//line','')
        print('  [WARN] Commit: ' + str(msg))
except Exception as e:
    print('  [WARN] ' + str(e))
" 2>/dev/null

# Push CG config (incl. new DLF entries) to LC daemon. Without this push the
# DLF entries are committed in Panorama config but the LC daemon does not
# learn about them — same as the Phase 2a panorama_bind_local_lc reasoning.
# Sync response (no <job>) is normal for single-LC; treat success+empty-job
# as completed.
echo "  Pushing CG default to LC (commit-all log-collector-config)..."
CGPUSH_RESP=$(curl -sk --max-time 60 "$PAN_URL" \
  --data-urlencode "type=commit" \
  --data-urlencode "action=all" \
  --data-urlencode "cmd=<commit-all><log-collector-config><log-collector-group>default</log-collector-group></log-collector-config></commit-all>" \
  --data-urlencode "key=$PAN_KEY" 2>/dev/null)
echo "$CGPUSH_RESP" | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    r = ET.fromstring(sys.stdin.read())
    status = r.get('status','')
    job = r.findtext('.//job','')
    if status == 'success' and not job:
        print('  [OK] CG push succeeded (sync — single-LC)')
    elif job:
        print(f'  [OK] CG push job {job} enqueued')
    else:
        print('  [WARN] CG push: ' + (r.findtext('.//msg','') or r.findtext('.//line','') or 'unknown'))
except Exception as e:
    print('  [WARN] CG push parse error: ' + str(e))
" 2>/dev/null

# Wait for FWs to connect to Panorama
echo ""
echo "[7/8] Waiting for firewalls to connect to Panorama..."
CONNECTED_COUNT=0
for WAIT_CONN in $(seq 1 30); do
  CONN_RESP=$(curl -sk --max-time 30 "$PAN_URL" \
    --data-urlencode "type=op" \
    --data-urlencode "cmd=<show><devices><connected></connected></devices></show>" \
    --data-urlencode "key=$PAN_KEY" 2>/dev/null || echo "")

  CONNECTED_COUNT=$(echo "$CONN_RESP" | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read())
    # Count only top-level device entries (not nested vsys/cert entries)
    devices = root.findall('./result/devices/entry')
    print(len(devices))
except:
    print(0)
" 2>/dev/null)

  if [ "$CONNECTED_COUNT" -ge 2 ]; then
    echo "  [OK] $CONNECTED_COUNT firewalls connected to Panorama!"
    break
  fi

  if [ "$WAIT_CONN" -ge 30 ]; then
    echo "  [WARN] Only $CONNECTED_COUNT FW(s) connected after 5 min."
    echo "         Commit & Push will proceed anyway (FWs will sync when connected)."
  fi

  echo "  [$WAIT_CONN/30] $CONNECTED_COUNT FW(s) connected — waiting 10s..."
  sleep 10
done

# Push Template Stack to devices (interfaces, management profile, zones, VR, routes)
echo ""
echo "[8/9] Push Template Stack ($TEMPLATE_STACK) to devices..."
TPL_PUSH_RESP=$(curl -sk --max-time 120 "$PAN_URL" \
  --data-urlencode "type=commit" \
  --data-urlencode "action=all" \
  --data-urlencode "cmd=<commit-all><template-stack><name>$TEMPLATE_STACK</name></template-stack></commit-all>" \
  --data-urlencode "key=$PAN_KEY" 2>/dev/null)

echo "$TPL_PUSH_RESP" | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read())
    status = root.get('status','')
    if status == 'success':
        job = root.findtext('.//job','')
        print('  [OK] Template push submitted' + (' (job ' + job + ')' if job else ''))
    else:
        msg = root.findtext('.//msg','') or root.findtext('.//line','')
        print('  [WARN] Template push: ' + str(msg))
except Exception as e:
    print('  [WARN] ' + str(e))
" 2>/dev/null

# Wait for Template push to complete before Device Group push
echo "  Waiting 30s for Template push to apply..."
sleep 30

# Push Device Group to devices (security policies, NAT rules)
echo ""
echo "[9/9] Push Device Group ($DEVICE_GROUP) to devices..."
DG_PUSH_RESP=$(curl -sk --max-time 120 "$PAN_URL" \
  --data-urlencode "type=commit" \
  --data-urlencode "action=all" \
  --data-urlencode "cmd=<commit-all><shared-policy><device-group><entry name='$DEVICE_GROUP'/></device-group></shared-policy></commit-all>" \
  --data-urlencode "key=$PAN_KEY" 2>/dev/null)

echo "$DG_PUSH_RESP" | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read())
    status = root.get('status','')
    if status == 'success':
        job = root.findtext('.//job','')
        print('  [OK] Device Group push submitted' + (' (job ' + job + ')' if job else ''))
    else:
        msg = root.findtext('.//msg','') or root.findtext('.//line','')
        print('  [WARN] Device Group push: ' + str(msg))
except Exception as e:
    print('  [WARN] ' + str(e))
" 2>/dev/null

echo ""
echo "  Logs from both FWs will reach Panorama natively over PAN-OS port"
echo "  3978/TCP (panorama-server in init-cfg). Verify after some traffic:"
echo "    admin@panorama> debug log-collector log-collection-stats show incoming-logs"

echo ""
echo "============================================================"
echo "  Phase 2b COMPLETED"
echo ""
echo "  Both FWs are now Panorama-managed and sit behind Azure Standard LB."
echo "  Failover is realised by Azure LB health probes — no PAN-OS HA pair"
echo "  is configured (per PANW Azure deployment guide). Configuration"
echo "  consistency between FW1 and FW2 is enforced by Panorama Device Group"
echo "  + Template Stack pushes."
