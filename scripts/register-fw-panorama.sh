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
  local url="$1" api_key="$2"
  curl -sk --max-time 30 \
    "$url/api/?type=op&cmd=<show><system><info></info></system></show>&key=$api_key" 2>/dev/null \
    | python3 -c "
import sys, xml.etree.ElementTree as ET
root = ET.fromstring(sys.stdin.read())
serial = root.findtext('.//serial', 'unknown')
print(serial)
" 2>/dev/null
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

# Read serials
echo ""
echo "  Reading serial numbers..."
FW1_SERIAL=$(get_serial "https://127.0.0.1:$FW1_PORT" "$FW1_KEY")
FW2_SERIAL=$(get_serial "https://127.0.0.1:$FW2_PORT" "$FW2_KEY")

echo "  FW1 serial: $FW1_SERIAL"
echo "  FW2 serial: $FW2_SERIAL"

if [ "$FW1_SERIAL" = "unknown" ] || [ "$FW2_SERIAL" = "unknown" ]; then
  echo "[ERROR] Failed to read serial. Check if FW license is active."
  echo "        SSH to FW: show system info | match serial"
  exit 1
fi

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

# HA peer mapping: FW1 sees FW2 as peer, FW2 sees FW1 as peer
# Lower priority wins election → FW1 (100) is active, FW2 (200) is passive
# HA config is pushed DIRECTLY to each FW via target=<serial>, NOT via
# Template Variables (which proved unreliable for <peer-ip> field substitution).
register_fw() {
  local serial="$1" peer_ip="$2" priority="$3" label="$4"
  echo "  $label  serial=$serial  peer-ip=$peer_ip  priority=$priority"

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
  TS_DEV_XPATH="/config/devices/entry[@name='localhost.localdomain']/template-stack/entry[@name='$TEMPLATE_STACK']/devices"
  curl -sk --max-time 30 "$PAN_URL" \
    --data-urlencode "type=config" \
    --data-urlencode "action=set" \
    --data-urlencode "xpath=$TS_DEV_XPATH" \
    --data-urlencode "element=<entry name='$serial'/>" \
    --data-urlencode "key=$PAN_KEY" > /dev/null

  echo "    OK (registration)"
}

# Wait for the FW to have no active/pending jobs (commit, push, etc.) so the
# next config write does not get rejected with "A commit is pending. Please
# try again later." (PAN-OS error code 13). This is exactly what bit us on
# the previous run — Template Stack and Device Group pushes from Panorama
# were still being applied on the FW when push_ha_config tried to set HA.
wait_for_fw_commit_idle() {
  local fw_url="$1" fw_key="$2" label="$3"
  echo "  $label  Waiting for FW commit to be idle..."
  local MAX=72   # 72 x 5s = 6 min hard cap
  for ATTEMPT in $(seq 1 $MAX); do
    JOBS_RESP=$(curl -sk --max-time 15 \
      "$fw_url/api/?type=op&cmd=<show><jobs><all></all></jobs></show>&key=$fw_key" 2>/dev/null || echo "")
    PENDING=$(echo "$JOBS_RESP" | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read())
    pending = 0
    for j in root.findall('.//job'):
        status = (j.findtext('status','') or '').upper()
        if status in ('ACT','PEND','PEN'):
            pending += 1
    print(pending)
except Exception:
    print(0)
" 2>/dev/null)
    if [ -z "$PENDING" ]; then PENDING=0; fi

    if [ "$PENDING" = "0" ]; then
      # Probe: try the cheapest possible config-lock check
      PROBE=$(curl -sk --max-time 15 \
        "$fw_url/api/?type=op&cmd=<check><pending-changes></pending-changes></check>&key=$fw_key" 2>/dev/null \
        | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    print(ET.fromstring(sys.stdin.read()).get('status',''))
except Exception:
    print('')
" 2>/dev/null)
      if [ "$PROBE" = "success" ]; then
        echo "    OK (no pending jobs, config lock free, attempt $ATTEMPT)"
        return 0
      fi
    fi

    echo "    [$ATTEMPT/$MAX] $PENDING pending job(s) — waiting 5s..."
    sleep 5
  done
  echo "    [WARN] FW $label still has pending jobs after $((MAX*5))s — proceeding anyway"
}

# Push HA config DIRECTLY to one FW via its own Bastion tunnel (NOT via
# Panorama target=<serial>, because PAN-OS API target= is supported for
# type=op and type=commit but NOT for type=config — earlier attempts with
# target= silently no-oped, leaving HA off).
#
# Includes a retry loop for the "A commit is pending" error (PAN-OS code 13)
# in case wait_for_fw_commit_idle missed a late-starting background job.
push_ha_config() {
  local fw_url="$1" fw_key="$2" peer_ip="$3" priority="$4" label="$5"
  echo "  $label  HA: peer-ip=$peer_ip, device-priority=$priority (via $fw_url)"

  HA_XPATH="/config/devices/entry[@name='localhost.localdomain']/deviceconfig/high-availability"
  # Minimum-viable HA XML — PAN-OS schema for <active-passive> is empty in
  # 11.x (passive-link-state default is "auto" and lives at a different level
  # in newer schema; including it inside <active-passive> trips
  # 'unexpected here' validation, code 12). We keep this XML lean and let
  # PAN-OS supply defaults for everything except the values that MUST differ
  # between FW1 and FW2 (peer-ip, device-priority).
  HA_ELEMENT="<enabled>yes</enabled><group><group-id>1</group-id><peer-ip>$peer_ip</peer-ip><mode><active-passive/></mode><configuration-synchronization><enabled>yes</enabled></configuration-synchronization><election-option><device-priority>$priority</device-priority><preemptive>no</preemptive></election-option></group><interface><ha1><port>management</port></ha1><ha2><port>ethernet1/3</port></ha2></interface>"

  for ATTEMPT in 1 2 3 4 5; do
    HA_RESP=$(curl -sk --max-time 30 "$fw_url/api/" \
      --data-urlencode "type=config" \
      --data-urlencode "action=set" \
      --data-urlencode "xpath=$HA_XPATH" \
      --data-urlencode "element=$HA_ELEMENT" \
      --data-urlencode "key=$fw_key" 2>/dev/null)

    HA_STATUS=$(echo "$HA_RESP" | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read())
    print(root.get('status', 'unknown'))
except Exception as e:
    print('parse-error: ' + str(e))
" 2>/dev/null)

    if [ "$HA_STATUS" = "success" ]; then
      echo "    OK (HA config set on FW candidate config, attempt $ATTEMPT)"
      return 0
    fi

    MSG=$(echo "$HA_RESP" | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read())
    print(root.findtext('.//msg','') or root.findtext('.//line','') or 'no message')
except: print('unparseable')
" 2>/dev/null)

    if echo "$MSG" | grep -qi "commit is pending"; then
      WAIT=$((ATTEMPT * 15))
      echo "    [$ATTEMPT/5] $MSG — waiting ${WAIT}s and retrying..."
      sleep $WAIT
    else
      echo "    [WARN] HA set returned status=$HA_STATUS msg=$MSG"
      echo "    Raw response (first 400 chars): $(echo "$HA_RESP" | head -c 400)"
      return 1
    fi
  done

  echo "    [ERROR] HA set still rejected after 5 retries — FW commit lock never freed."
  echo "    Try manually: SSH to FW, run 'show jobs all', wait for ACT/PEND to drain, re-run this script."
  return 1
}

# Poll a FW commit job until it reaches FIN (success or failure) and surface
# the result. Without this the script previously reported 'commit submitted'
# but never noticed when the job itself failed during PAN-OS validation —
# leaving the user with 'HA not enabled' and no clear error.
wait_for_fw_job_complete() {
  local fw_url="$1" fw_key="$2" job_id="$3" label="$4"
  echo "    Polling commit job $job_id for completion..."
  local MAX=60   # 60 x 5s = 5 min
  for i in $(seq 1 $MAX); do
    JOB_RESP=$(curl -sk --max-time 15 \
      "$fw_url/api/?type=op&cmd=<show><jobs><id>$job_id</id></jobs></show>&key=$fw_key" 2>/dev/null || echo "")

    JOB_PARSED=$(echo "$JOB_RESP" | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read())
    job = root.find('.//job')
    if job is None:
        print('NOJOB|NOJOB|')
    else:
        status = job.findtext('status', '') or ''
        result = job.findtext('result', '') or ''
        # Collect failure detail lines (PAN-OS puts them under details/line)
        details = job.findall('.//details/line')
        msgs = [d.text.strip() for d in details if d.text and d.text.strip()]
        print(status + '|' + result + '|' + ' || '.join(msgs[:6]))
except Exception as e:
    print('ERR|ERR|' + str(e))
" 2>/dev/null)

    STATUS=$(echo "$JOB_PARSED" | cut -d'|' -f1)
    RESULT=$(echo "$JOB_PARSED" | cut -d'|' -f2)
    DETAILS=$(echo "$JOB_PARSED" | cut -d'|' -f3-)

    if [ "$STATUS" = "FIN" ]; then
      if [ "$RESULT" = "OK" ]; then
        echo "    OK ($label commit job $job_id completed successfully)"
        return 0
      else
        echo "    [ERROR] $label commit job $job_id finished with result=$RESULT"
        if [ -n "$DETAILS" ]; then
          echo "    Details: $DETAILS"
        fi
        return 1
      fi
    fi

    if [ $((i % 6)) -eq 0 ]; then   # Every 30s
      echo "    [${i}/$MAX] Job $job_id status=$STATUS — still running..."
    fi
    sleep 5
  done
  echo "    [WARN] $label commit job $job_id did not finish within $((MAX*5))s"
  return 1
}

# Commit the FW's local candidate config (where the HA settings now live).
# Direct to FW via its own tunnel — same reasoning as push_ha_config above.
# Polls the resulting job to confirm commit ACTUALLY succeeded (PAN-OS commit
# returns a job ID immediately; the validation/apply phase can still fail
# with errors that only show up in `show jobs id <N>` details).
commit_on_fw() {
  local fw_url="$1" fw_key="$2" label="$3"
  echo "  $label  Committing on FW (direct via $fw_url)..."

  COMMIT_RESP=$(curl -sk --max-time 90 "$fw_url/api/" \
    --data-urlencode "type=commit" \
    --data-urlencode "cmd=<commit></commit>" \
    --data-urlencode "key=$fw_key" 2>/dev/null)

  COMMIT_RESULT=$(echo "$COMMIT_RESP" | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read())
    if root.get('status') == 'success':
        print('OK:' + root.findtext('.//job','submitted'))
    else:
        msg = root.findtext('.//msg','') or root.findtext('.//line','') or 'unknown'
        print('FAIL: ' + str(msg))
except: print('parse-error')
" 2>/dev/null)

  if echo "$COMMIT_RESULT" | grep -q "^FAIL"; then
    echo "    [WARN] FW commit submit: $COMMIT_RESULT"
    echo "    Raw response (first 400 chars): $(echo "$COMMIT_RESP" | head -c 400)"
    return 1
  fi

  COMMIT_JOB_ID=$(echo "$COMMIT_RESULT" | sed 's/^OK://')
  echo "    Submitted as job $COMMIT_JOB_ID — polling for actual result..."
  wait_for_fw_job_complete "$fw_url" "$fw_key" "$COMMIT_JOB_ID" "$label"
}

register_fw "$FW1_SERIAL" "$FW2_MGMT_IP" "100" "FW1 (active)"
register_fw "$FW2_SERIAL" "$FW1_MGMT_IP" "200" "FW2 (passive)"

# Add FW devices to Collector Group's Device Log Forwarding
echo ""
echo "[5.5/6] Adding FWs to Collector Group 'default' Device Log Forwarding..."

# Get Panorama serial (Log Collector serial = Panorama serial in local LC mode)
PAN_SERIAL=$(curl -sk --max-time 30 \
  "https://127.0.0.1:$PANORAMA_PORT/api/?type=op&cmd=<show><system><info></info></system></show>&key=$PAN_KEY" 2>/dev/null \
  | python3 -c "
import sys, xml.etree.ElementTree as ET
root = ET.fromstring(sys.stdin.read())
print(root.findtext('.//serial','unknown'))
" 2>/dev/null)

if [ "$PAN_SERIAL" != "unknown" ] && [ -n "$PAN_SERIAL" ]; then
  echo "  Panorama/LC serial: $PAN_SERIAL"

  # Add Device Log Forwarding preference list mapping FWs → Log Collector
  CG_XPATH="/config/panorama/collector-group/entry[@name='default']/logfwd-setting/device"
  for SERIAL in "$FW1_SERIAL" "$FW2_SERIAL"; do
    echo "  Adding $SERIAL → Collector Group log forwarding..."
    curl -sk --max-time 30 "$PAN_URL" \
      --data-urlencode "type=config" \
      --data-urlencode "action=set" \
      --data-urlencode "xpath=$CG_XPATH" \
      --data-urlencode "element=<entry name='$SERIAL'><collector><entry name='$PAN_SERIAL'/></collector></entry>" \
      --data-urlencode "key=$PAN_KEY" > /dev/null
  done
  echo "  [OK] FWs added to Collector Group Device Log Forwarding"
else
  echo "  [WARN] Could not get Panorama serial — skipping Collector Group update."
  echo "         Manual: Panorama → Collector Groups → default → Device Log Forwarding → Add FWs"
fi

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

# Push Collector Group (to apply Device Log Forwarding with FW serials)
echo ""
echo "[9.5/9] Push Collector Group 'default'..."
CG_PUSH_RESP=$(curl -sk --max-time 120 "$PAN_URL" \
  --data-urlencode "type=commit" \
  --data-urlencode "action=all" \
  --data-urlencode "cmd=<commit-all><log-collector-config><collector-group>default</collector-group></log-collector-config></commit-all>" \
  --data-urlencode "key=$PAN_KEY" 2>/dev/null || echo "")

echo "$CG_PUSH_RESP" | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read())
    status = root.get('status','')
    if status == 'success':
        job = root.findtext('.//job','')
        print('  [OK] Collector Group push submitted' + (' (job ' + job + ')' if job else ''))
    else:
        msg = root.findtext('.//msg','') or root.findtext('.//line','')
        print('  [INFO] Collector Group push: ' + str(msg))
except Exception as e:
    print('  [INFO] Collector Group push: ' + str(e))
" 2>/dev/null

# Push HA configuration directly to each FW via its own Bastion tunnel. Each
# FW gets a complete HA config with its actual peer IP and priority baked in.
# This goes into the FW's LOCAL candidate config — committed below.
echo ""
echo "[9.7/9] Pushing HA configuration directly to each FW..."

# Refresh API keys on each FW — they were obtained ~5-10 min ago at step [3/6]
# and a long Phase 2b run can hit Panorama-side commits that occasionally
# invalidate FW-side admin sessions.
echo "  Refreshing FW API keys..."
FW1_KEY=$(get_api_key "https://127.0.0.1:$FW1_PORT" "$PAN_USER" "$PAN_PASS" 2>/dev/null)
FW2_KEY=$(get_api_key "https://127.0.0.1:$FW2_PORT" "$PAN_USER" "$PAN_PASS" 2>/dev/null)
if [ -z "$FW1_KEY" ] || echo "$FW1_KEY" | grep -q "^ERROR"; then
  echo "  [ERROR] Could not refresh FW1 API key — HA push will be skipped."
  echo "          Re-run scripts/register-fw-panorama.sh."
  exit 1
fi
if [ -z "$FW2_KEY" ] || echo "$FW2_KEY" | grep -q "^ERROR"; then
  echo "  [ERROR] Could not refresh FW2 API key — HA push will be skipped."
  exit 1
fi

# Wait for both FWs to finish processing the Template Stack / Device Group /
# Collector Group pushes from Panorama before touching the FW config. Without
# this wait the previous run's HA push bombed with PAN-OS error code 13
# "A commit is pending. Please try again later." (the static 30s sleep was
# not enough for big template pushes — they routinely take 60-120s).
echo ""
wait_for_fw_commit_idle "https://127.0.0.1:$FW1_PORT" "$FW1_KEY" "FW1"
wait_for_fw_commit_idle "https://127.0.0.1:$FW2_PORT" "$FW2_KEY" "FW2"

push_ha_config "https://127.0.0.1:$FW1_PORT" "$FW1_KEY" "$FW2_MGMT_IP" "100" "FW1 (active)"
push_ha_config "https://127.0.0.1:$FW2_PORT" "$FW2_KEY" "$FW1_MGMT_IP" "200" "FW2 (passive)"

# Commit on each FW so the HA candidate config becomes running config — HA
# only forms after both peers have committed and brought up the HA1 link.
echo ""
echo "[9.8/9] Committing HA config on each FW..."
commit_on_fw "https://127.0.0.1:$FW1_PORT" "$FW1_KEY" "FW1"
commit_on_fw "https://127.0.0.1:$FW2_PORT" "$FW2_KEY" "FW2"

echo ""
echo "  HA negotiation typically takes 30-60s after both FWs commit."
echo "  Verify with: show high-availability state on each FW."

echo ""
echo "============================================================"
echo "  Phase 2b COMPLETED"
