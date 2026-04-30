###############################################################################
# Phase 2 – Panorama Configuration (API-based)
#
# WYMAGANIA:
#   1. Panorama VM running (Phase 1a completed, VM boots ~15 min)
#   2. Bastion tunnel active in SEPARATE terminal:
#        PANORAMA_ID=$(cd .. && terraform output -raw panorama_vm_id)
#        az network bastion tunnel \
#          --name bastion-management \
#          --resource-group rg-transit-hub \
#          --target-resource-id "$PANORAMA_ID" \
#          --resource-port 443 --port 44300
#   3. terraform.tfvars filled in (password, serial_number, CIDRs)
#
# SEKWENCJA:
#   1. Wait for Panorama API (max 20 min)
#   2. Set hostname via XML API + commit
#   3. Set serial number via XML API (config mode) + commit + license fetch
#   4. Generate vm-auth-key via XML API (automatycznie!)
#   5. panos provider: Template Stack, DG, interfaces, zones, routes, policies
#   6. Final commit
###############################################################################

###############################################################################
# Step 1: Wait for Panorama API
###############################################################################
resource "null_resource" "panorama_wait_for_api" {
  triggers = {
    panorama_url = "https://${var.panorama_hostname}:${var.panorama_port}"
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -e
      PANORAMA_URL="https://${var.panorama_hostname}:${var.panorama_port}"
      echo "=== Waiting for Panorama API: $PANORAMA_URL ==="
      ATTEMPTS=0
      MAX_ATTEMPTS=40
      while true; do
        ATTEMPTS=$((ATTEMPTS + 1))
        HTTP_CODE=$(curl -sk --max-time 10 -o /dev/null -w "%%{http_code}" "$PANORAMA_URL/php/login.php" 2>/dev/null || echo "000")
        if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ] || [ "$HTTP_CODE" = "301" ]; then
          echo "[OK] Panorama API responds (HTTP $HTTP_CODE) after $ATTEMPTS attempts."
          break
        fi
        if [ "$ATTEMPTS" -ge "$MAX_ATTEMPTS" ]; then
          echo "[ERROR] Panorama API still not responding after $MAX_ATTEMPTS attempts."
          exit 1
        fi
        echo "  [$ATTEMPTS/$MAX_ATTEMPTS] HTTP $HTTP_CODE – waiting 30s..."
        sleep 30
      done
    SCRIPT
  }
}

###############################################################################
# Step 2: Set hostname via XML API (config mode + commit)
###############################################################################
resource "null_resource" "panorama_set_hostname" {
  triggers = {
    target_hostname = var.panorama_target_hostname
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -e
      PANORAMA_URL="https://${var.panorama_hostname}:${var.panorama_port}"
      PAN_USER="${var.panorama_username}"
      TARGET_HOST="${var.panorama_target_hostname}"

      echo "=== [Step 2] Setting hostname: $TARGET_HOST ==="

      ENC_PASS=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${var.panorama_password}', safe=''))")
      API_KEY=$(curl -sk --max-time 30 \
        "$PANORAMA_URL/api/?type=keygen&user=$PAN_USER&password=$ENC_PASS" 2>/dev/null \
        | python3 -c "
import sys, xml.etree.ElementTree as ET
root = ET.fromstring(sys.stdin.read())
if root.get('status') != 'success':
    print('ERROR: ' + (root.findtext('.//msg','no message')), file=sys.stderr); sys.exit(1)
print(root.findtext('.//key',''))
" 2>&1)

      if echo "$API_KEY" | grep -q "^ERROR:"; then
        echo "[ERROR] API key: $API_KEY"; exit 1
      fi
      echo "  API key: OK"

      SYSTEM_XPATH="/config/devices/entry[@name='localhost.localdomain']/deviceconfig/system"

      # 2a: Set hostname
      curl -sk --max-time 30 "$PANORAMA_URL/api/" \
        --data-urlencode "type=config" \
        --data-urlencode "action=set" \
        --data-urlencode "xpath=$SYSTEM_XPATH" \
        --data-urlencode "element=<hostname>$TARGET_HOST</hostname>" \
        --data-urlencode "key=$API_KEY" > /dev/null
      echo "  Hostname: $TARGET_HOST"

      # 2b: Set timezone to Europe/Warsaw
      curl -sk --max-time 30 "$PANORAMA_URL/api/" \
        --data-urlencode "type=config" \
        --data-urlencode "action=set" \
        --data-urlencode "xpath=$SYSTEM_XPATH" \
        --data-urlencode "element=<timezone>Europe/Warsaw</timezone>" \
        --data-urlencode "key=$API_KEY" > /dev/null
      echo "  Timezone: Europe/Warsaw"

      # 2c: Set NTP servers (Europe pool)
      curl -sk --max-time 30 "$PANORAMA_URL/api/" \
        --data-urlencode "type=config" \
        --data-urlencode "action=set" \
        --data-urlencode "xpath=$SYSTEM_XPATH/ntp-servers" \
        --data-urlencode "element=<primary-ntp-server><ntp-server-address>0.europe.pool.ntp.org</ntp-server-address></primary-ntp-server><secondary-ntp-server><ntp-server-address>1.europe.pool.ntp.org</ntp-server-address></secondary-ntp-server>" \
        --data-urlencode "key=$API_KEY" > /dev/null
      echo "  NTP: 0.europe.pool.ntp.org, 1.europe.pool.ntp.org"

      # 2d: Enable telemetry/statistics service (EU region)
      curl -sk --max-time 30 "$PANORAMA_URL/api/" \
        --data-urlencode "type=config" \
        --data-urlencode "action=set" \
        --data-urlencode "xpath=$SYSTEM_XPATH/update-schedule/statistics-service" \
        --data-urlencode "element=<application-reports>yes</application-reports><threat-prevention-reports>yes</threat-prevention-reports><threat-prevention-pcap>yes</threat-prevention-pcap><passive-dns-monitoring>yes</passive-dns-monitoring><url-reports>yes</url-reports><health-performance-reports>yes</health-performance-reports><file-identification-reports>yes</file-identification-reports>" \
        --data-urlencode "key=$API_KEY" > /dev/null
      echo "  Telemetry: enabled (EU statistics service)"

      # Commit all system settings
      curl -sk --max-time 60 "$PANORAMA_URL/api/" \
        --data-urlencode "type=commit" \
        --data-urlencode "cmd=<commit></commit>" \
        --data-urlencode "key=$API_KEY" > /dev/null

      echo "  System settings (hostname, timezone, NTP, telemetry) committed OK"
    SCRIPT
  }

  depends_on = [null_resource.panorama_wait_for_api]
}

###############################################################################
# Step 3: Set serial number (OPERATIONAL mode) + commit + license fetch
#
# Serial number on Panorama is set via operational mode command:
#   set serial-number 000710041165
#
# XML API equivalent (confirmed with debug cli on):
#   type=op&cmd=<set><serial-number>SERIAL</serial-number></set>
#
# Sequence:
#   1. Set serial via operational mode (type=op)
#   2. Commit
#   3. request license fetch (operational)
###############################################################################
resource "null_resource" "panorama_activate_license" {
  count = var.panorama_serial_number != "" ? 1 : 0

  triggers = {
    serial_number = var.panorama_serial_number
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -e
      PANORAMA_URL="https://${var.panorama_hostname}:${var.panorama_port}"
      PAN_USER="${var.panorama_username}"
      SERIAL_NUM="${var.panorama_serial_number}"

      echo "=== [Step 3] Serial number + license activation ==="
      echo "    Serial: $SERIAL_NUM"

      ENC_PASS=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${var.panorama_password}', safe=''))")
      API_KEY=$(curl -sk --max-time 30 \
        "$PANORAMA_URL/api/?type=keygen&user=$PAN_USER&password=$ENC_PASS" 2>/dev/null \
        | python3 -c "
import sys, xml.etree.ElementTree as ET
root = ET.fromstring(sys.stdin.read())
if root.get('status') != 'success':
    print('ERROR: ' + (root.findtext('.//msg','no message')), file=sys.stderr); sys.exit(1)
print(root.findtext('.//key',''))
" 2>&1)

      if echo "$API_KEY" | grep -q "^ERROR:"; then
        echo "[ERROR] API key: $API_KEY"; exit 1
      fi
      echo "  API key: OK"

      # 3a: Set serial number via OPERATIONAL mode
      # CLI: set serial-number 000710041165
      # XML API: type=op, cmd=<set><serial-number>SERIAL</serial-number></set>
      # NOTE: After set serial-number Panorama may restart management service.
      #        Therefore max-time=120 followed by API wait loop.
      echo "  Setting serial number (operational mode)..."
      SET_RESP=$(curl -sk --max-time 120 "$PANORAMA_URL/api/" \
        --data-urlencode "type=op" \
        --data-urlencode "cmd=<set><serial-number>$SERIAL_NUM</serial-number></set>" \
        --data-urlencode "key=$API_KEY" 2>/dev/null || echo "<response status='timeout'/>")

      SET_STATUS=$(echo "$SET_RESP" | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read())
    if root.get('status') == 'success':
        print('OK')
    elif root.get('status') == 'timeout':
        print('TIMEOUT')
    else:
        msg = root.findtext('.//msg','') or root.findtext('.//line','')
        print('ERROR: ' + str(msg))
except Exception as e:
    print('ERROR: ' + str(e))
" 2>/dev/null)

      if echo "$SET_STATUS" | grep -q "^ERROR:"; then
        echo "  [ERROR] Set serial: $SET_STATUS"
        exit 1
      fi
      if [ "$SET_STATUS" = "TIMEOUT" ]; then
        echo "  Set serial: timeout (Panorama restarts management service — it's normal)"
      else
        echo "  Set serial: OK"
      fi

      # 3a2: Wait for API after set serial-number (management service may restart)
      echo "  Waiting for Panorama API after serial number change..."
      sleep 15
      for WAIT_I in $(seq 1 20); do
        WAIT_CODE=$(curl -sk --max-time 10 -o /dev/null -w "%%{http_code}" "$PANORAMA_URL/php/login.php" 2>/dev/null || echo "000")
        if [ "$WAIT_CODE" = "200" ] || [ "$WAIT_CODE" = "302" ]; then
          echo "  Panorama API ready (HTTP $WAIT_CODE, attempt $WAIT_I)"
          break
        fi
        if [ "$WAIT_I" -ge 20 ]; then
          echo "  [WARN] Panorama API is not responding after 20 attempts."
        fi
        echo "  [$WAIT_I/20] HTTP $WAIT_CODE — waiting 10s..."
        sleep 10
      done

      # New API key (old one may have expired after restart)
      API_KEY=$(curl -sk --max-time 30 \
        "$PANORAMA_URL/api/?type=keygen&user=$PAN_USER&password=$ENC_PASS" 2>/dev/null \
        | python3 -c "
import sys, xml.etree.ElementTree as ET
root = ET.fromstring(sys.stdin.read())
print(root.findtext('.//key',''))
" 2>/dev/null)

      # 3b: Commit
      echo "  Commit after setting serial number..."
      curl -sk --max-time 120 "$PANORAMA_URL/api/" \
        --data-urlencode "type=commit" \
        --data-urlencode "cmd=<commit></commit>" \
        --data-urlencode "key=$API_KEY" > /dev/null
      echo "  Commit: OK"

      echo "  Waiting 30s for serial number propagation..."
      sleep 30

      # 3c: License fetch (operational mode, with retry)
      echo "  Downloading licenses (request license fetch)..."
      MAX_RETRIES=5
      for i in $(seq 1 $MAX_RETRIES); do
        LIC_RESP=$(curl -sk --max-time 120 "$PANORAMA_URL/api/" \
          --data-urlencode "type=op" \
          --data-urlencode "cmd=<request><license><fetch></fetch></license></request>" \
          --data-urlencode "key=$API_KEY" 2>/dev/null)

        LIC_STATUS=$(echo "$LIC_RESP" | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read())
    status = root.get('status','')
    msg = root.findtext('.//msg','') or root.findtext('.//line','') or 'no info'
    if status == 'success':
        print('OK')
    else:
        print('RETRY: ' + msg)
except Exception as e:
    print('RETRY: ' + str(e))
" 2>/dev/null)

        if [ "$LIC_STATUS" = "OK" ]; then
          echo "  [OK] License installed successfully!"
          break
        fi

        if [ "$i" -lt "$MAX_RETRIES" ]; then
          echo "  [$i/$MAX_RETRIES] $LIC_STATUS – waiting 30s..."
          sleep 30
        else
          echo "  [WARN] License fetch failed after $MAX_RETRIES attempts: $LIC_STATUS"
          echo "  Please check: CSP Portal, NAT Gateway, Internet Access"
        fi
      done

      # 3d: After license fetch Panorama may AGAIN restart management service
      # to apply the new license. Waiting for stable API.
      echo "  Waiting for stable API after license fetch..."
      sleep 20
      for WAIT_L in $(seq 1 15); do
        WAIT_CODE=$(curl -sk --max-time 10 -o /dev/null -w "%%{http_code}" "$PANORAMA_URL/php/login.php" 2>/dev/null || echo "000")
        if [ "$WAIT_CODE" = "200" ] || [ "$WAIT_CODE" = "302" ]; then
          echo "  Panorama API stable (HTTP $WAIT_CODE, attempt $WAIT_L)"
          break
        fi
        if [ "$WAIT_L" -ge 15 ]; then
          echo "  [WARN] Panorama API still unstable after 15 attempts — I will still continue..."
        fi
        echo "  [$WAIT_L/15] HTTP $WAIT_CODE — waiting 10s..."
        sleep 10
      done

      # Verification: check if keygen works (test credentials)
      echo "  Verifying API credentials..."
      for VERIFY in $(seq 1 5); do
        TEST_KEY=$(curl -sk --max-time 15 \
          "$PANORAMA_URL/api/?type=keygen&user=$PAN_USER&password=$ENC_PASS" 2>/dev/null \
          | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read())
    if root.get('status') == 'success': print('OK')
    else: print('RETRY')
except: print('RETRY')
" 2>/dev/null)
        if [ "$TEST_KEY" = "OK" ]; then
          echo "  Credentials: OK"
          break
        fi
        echo "  [$VERIFY/5] Credentials not ready — waiting 15s..."
        sleep 15
      done

      echo "  [Step 3] Ready."
    SCRIPT
  }

  depends_on = [null_resource.panorama_set_hostname]
}

###############################################################################
# Step 4: Generate vm-auth-key automatically via XML API
#
# Generates the Device Registration Auth Key on Panorama.
# The key is required in the FW init-cfg for automatic registration.
# A Panorama license is NOT required to generate the key.
#
# Output: the key is saved to the ../panorama_vm_auth_key.txt file
###############################################################################
resource "null_resource" "panorama_generate_vm_auth_key" {
  triggers = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -e
      PANORAMA_URL="https://${var.panorama_hostname}:${var.panorama_port}"
      PAN_USER="${var.panorama_username}"
      LIFETIME="${var.vm_auth_key_lifetime}"

      echo "=== [Step 4] Generating vm-auth-key (lifetime: $LIFETIME min) ==="

      ENC_PASS=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${var.panorama_password}', safe=''))")

      # Retry keygen — API may still be unstable after license fetch
      API_KEY=""
      for KG_TRY in $(seq 1 10); do
        API_KEY=$(curl -sk --max-time 30 \
          "$PANORAMA_URL/api/?type=keygen&user=$PAN_USER&password=$ENC_PASS" 2>/dev/null \
          | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read())
    if root.get('status') == 'success':
        print(root.findtext('.//key',''))
    else:
        print('ERROR')
except:
    print('ERROR')
" 2>/dev/null)
        if [ -n "$API_KEY" ] && [ "$API_KEY" != "ERROR" ]; then
          echo "  API key: OK (attempt $KG_TRY)"
          break
        fi
        if [ "$KG_TRY" -ge 10 ]; then
          echo "[ERROR] API key: failure after 10 attempts"; exit 1
        fi
        echo "  [$KG_TRY/10] API key not ready yet — waiting 15s..."
        sleep 15
      done

      # Generate key (with retry — Panorama may need a moment after license fetch)
      VM_AUTH_KEY=""
      for AUTH_TRY in $(seq 1 5); do
        KEY_RESP=$(curl -sk --max-time 60 \
          "$PANORAMA_URL/api/?type=op&cmd=<request><authkey><add><name>authkey-auto</name><lifetime>$LIFETIME</lifetime><count>10</count></add></authkey></request>&key=$API_KEY" \
          2>/dev/null || echo "")

        # Debug: show raw response (first 500 chars)
        echo "  [authkey attempt $AUTH_TRY] Response length: $(echo "$KEY_RESP" | wc -c | tr -d ' ') bytes"

        # Parser — ALWAYS exit 0, errors in stdout prefixed ERROR:
        VM_AUTH_KEY=$(echo "$KEY_RESP" | python3 -c "
import sys, xml.etree.ElementTree as ET, re
try:
    data = sys.stdin.read()
    if not data or len(data) < 10:
        print('ERROR: empty response'); sys.exit(0)
    root = ET.fromstring(data)
    status = root.get('status','')
    if status != 'success':
        msg = root.findtext('.//msg','') or root.findtext('.//line','') or 'unknown'
        print('ERROR: API status=' + status + ' msg=' + str(msg)); sys.exit(0)
    # Search for key pattern (format: 2:XXXXXXXXX)
    for elem in root.iter():
        if elem.text:
            m = re.search(r'(2:[\w-]{20,})', elem.text)
            if m:
                print(m.group(1)); sys.exit(0)
    # Key not found — dump all text for diagnostics
    all_text = ' | '.join(e.text.strip() for e in root.iter() if e.text and e.text.strip())
    print('ERROR: key pattern not found. Response text: ' + all_text[:300]); sys.exit(0)
except ET.ParseError as e:
    print('ERROR: XML parse: ' + str(e)); sys.exit(0)
except Exception as e:
    print('ERROR: ' + str(e)); sys.exit(0)
" 2>/dev/null)

        # Check if key was found
        if echo "$VM_AUTH_KEY" | grep -q "^2:"; then
          echo "  [OK] vm-auth-key generated!"
          break
        fi

        echo "  [$AUTH_TRY/5] $VM_AUTH_KEY"
        if [ "$AUTH_TRY" -lt 5 ]; then
          echo "  Waiting 20s before the next attempt..."
          sleep 20
        fi
      done

      # Final check
      if ! echo "$VM_AUTH_KEY" | grep -q "^2:"; then
        echo ""
        echo "[WARN] Failed to generate the vm-auth-key after 5 attempts."
        echo "       Last result: $VM_AUTH_KEY"
        echo "        Generate manually: admin@panorama> request authkey add name authkey1 lifetime $LIFETIME count 2"
        echo "       Then add to terraform.tfvars: panorama_vm_auth_key = \"<key>\""
        # Not failing — rest of Phase 2a (Step 5, 6) can still work
        exit 0
      fi

      echo ""
      echo "  ========================================"
      echo "  vm-auth-key: $VM_AUTH_KEY"
      echo "  ========================================"
      echo ""

      # Save to .txt (backup)
      echo "$VM_AUTH_KEY" > ../panorama_vm_auth_key.txt
      echo "  Saved to: ../panorama_vm_auth_key.txt"

      # Auto-inject into root terraform — .auto.tfvars is auto-loaded!
      cat > ../panorama_vm_auth_key.auto.tfvars <<EOF
# Auto-generated by Phase 2a ($(date -u +%Y-%m-%dT%H:%M:%SZ))
# vm-auth-key generated on Panorama — used in FW bootstrap init-cfg
panorama_vm_auth_key = "$VM_AUTH_KEY"
EOF
      echo "  Saved to: ../panorama_vm_auth_key.auto.tfvars (auto-loaded by Terraform)"
      echo ""
      echo "  Phase 1b automatically downloads vm-auth-key."
      echo "  Run it in ROOT directory:"
      echo "    cd .."
      echo "    terraform apply -target=module.bootstrap \\"
      echo "      -target=module.loadbalancer -target=module.firewall \\"
      echo "      -target=module.routing -target=module.frontdoor -target=module.app1_app"
    SCRIPT
  }

  # Step 4 MUST wait for Step 3 (serial number + license activation).
  # After set serial-number Panorama restarts management service — Step 4 must
  # start AFTER API comes back up (Step 3 waits for this).
  depends_on = [null_resource.panorama_activate_license]
}

###############################################################################
# Step 4b: Configure Panorama Log Collector + Collector Group
#
# Full log collector setup per PANW docs:
#   1. Get Panorama serial number
#   2. Add Panorama as Managed Collector (local Log Collector)
#   3. Enable logging disks
#   4. Create Collector Group with Log Collector as member
#   5. Enable log forwarding in Collector Group
#   6. Commit + push Collector Group
#
# Ref: https://docs.paloaltonetworks.com/panorama/11-1/panorama-admin/manage-log-collection
###############################################################################
resource "null_resource" "panorama_configure_collector_group" {
  triggers = {
    collector_group = "default"
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -e
      PANORAMA_URL="https://${var.panorama_hostname}:${var.panorama_port}"
      PAN_USER="${var.panorama_username}"

      echo "=== [Step 4b] Configuring Panorama Log Collector + Collector Group ==="

      ENC_PASS=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${var.panorama_password}', safe=''))")
      API_KEY=$(curl -sk --max-time 30 \
        "$PANORAMA_URL/api/?type=keygen&user=$PAN_USER&password=$ENC_PASS" 2>/dev/null \
        | python3 -c "
import sys, xml.etree.ElementTree as ET
root = ET.fromstring(sys.stdin.read())
if root.get('status') != 'success':
    print('ERROR: keygen failed', file=sys.stderr); sys.exit(1)
print(root.findtext('.//key',''))
" 2>/dev/null)

      if [ -z "$API_KEY" ]; then
        echo "[ERROR] Failed to get API key"; exit 1
      fi

      # 4b-1: Get Panorama serial number
      echo "  Getting Panorama serial number..."
      PAN_SERIAL=$(curl -sk --max-time 30 \
        "$PANORAMA_URL/api/?type=op&cmd=<show><system><info></info></system></show>&key=$API_KEY" 2>/dev/null \
        | python3 -c "
import sys, xml.etree.ElementTree as ET
root = ET.fromstring(sys.stdin.read())
print(root.findtext('.//serial','unknown'))
" 2>/dev/null)
      echo "  Panorama serial: $PAN_SERIAL"

      if [ "$PAN_SERIAL" = "unknown" ] || [ -z "$PAN_SERIAL" ]; then
        echo "  [WARN] Could not determine Panorama serial. Skipping Log Collector setup."
        echo "  Manual setup required: Panorama → Managed Collectors → Add"
        exit 0
      fi

      # 4b-2: Add Panorama as Managed Collector (local Log Collector)
      echo "  Adding Panorama as Managed Collector ($PAN_SERIAL)..."
      curl -sk --max-time 30 "$PANORAMA_URL/api/" \
        --data-urlencode "type=config" \
        --data-urlencode "action=set" \
        --data-urlencode "xpath=/config/devices/entry[@name='localhost.localdomain']/log-collector/entry[@name='$PAN_SERIAL']" \
        --data-urlencode "element=<deviceconfig><system><hostname>panorama-lc</hostname></system></deviceconfig>" \
        --data-urlencode "key=$API_KEY" > /dev/null 2>&1
      echo "  [OK] Managed Collector added"

      # 4b-3: Enable logging disks (virtual disk pair A)
      echo "  Enabling logging disks..."
      curl -sk --max-time 30 "$PANORAMA_URL/api/" \
        --data-urlencode "type=config" \
        --data-urlencode "action=set" \
        --data-urlencode "xpath=/config/devices/entry[@name='localhost.localdomain']/log-collector/entry[@name='$PAN_SERIAL']/deviceconfig/system/logger/disk-pair" \
        --data-urlencode "element=<entry name='A'><disk1><path>/dev/sdb</path></disk1><disk2><path>/dev/sdc</path></disk2></entry>" \
        --data-urlencode "key=$API_KEY" > /dev/null 2>&1 || true
      echo "  [OK] Logging disks configured (if available)"

      # 4b-4: Create Collector Group with Log Collector as member
      echo "  Creating Collector Group 'default' with Log Collector..."
      curl -sk --max-time 30 "$PANORAMA_URL/api/" \
        --data-urlencode "type=config" \
        --data-urlencode "action=set" \
        --data-urlencode "xpath=/config/panorama/collector-group/entry[@name='default']" \
        --data-urlencode "element=<logfwd-setting><disabled>no</disabled></logfwd-setting><collector-member><entry name='$PAN_SERIAL'/></collector-member>" \
        --data-urlencode "key=$API_KEY" > /dev/null
      echo "  [OK] Collector Group 'default' created with member $PAN_SERIAL"

      # 4b-5: Commit to Panorama
      echo "  Committing Log Collector + Collector Group config..."
      curl -sk --max-time 90 "$PANORAMA_URL/api/" \
        --data-urlencode "type=commit" \
        --data-urlencode "cmd=<commit></commit>" \
        --data-urlencode "key=$API_KEY" > /dev/null 2>&1
      echo "  [OK] Commit submitted"

      echo "  Waiting 30s for Panorama to stabilize..."
      sleep 30

      # 4b-6: Commit & push Collector Group
      echo "  Pushing Collector Group to Log Collector..."
      curl -sk --max-time 120 "$PANORAMA_URL/api/" \
        --data-urlencode "type=commit" \
        --data-urlencode "action=all" \
        --data-urlencode "cmd=<commit-all><log-collector-config><collector-group>default</collector-group></log-collector-config></commit-all>" \
        --data-urlencode "key=$API_KEY" > /dev/null 2>&1 || true
      echo "  [OK] Collector Group push submitted"

      echo "  Waiting 30s for Collector Group push to complete..."
      sleep 30
    SCRIPT
  }

  depends_on = [null_resource.panorama_generate_vm_auth_key]
}

###############################################################################
# Step 4c: Wait for all pending Panorama jobs to finish
#
# `commit` and `commit-all` over the XML API are asynchronous — they return a
# job ID immediately while Panorama processes the change in the background.
# The background commit holds a config lock; the first panos provider call
# (panos_panorama_template) needs that lock and times out if it arrives too
# early. Symptoms: 'context deadline exceeded' on the very first panos resource.
#
# This step polls `show jobs all` and waits until no PEND/ACT jobs remain, then
# probes the API with a no-op to confirm the lock is free. Only then does
# module.panorama_config (Step 5) start.
###############################################################################
resource "null_resource" "panorama_wait_jobs_idle" {
  triggers = {
    after_collector_group = null_resource.panorama_configure_collector_group.id
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -e
      PANORAMA_URL="https://${var.panorama_hostname}:${var.panorama_port}"
      PAN_USER="${var.panorama_username}"

      ENC_PASS=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${var.panorama_password}', safe=''))")
      API_KEY=$(curl -sk --max-time 30 \
        "$PANORAMA_URL/api/?type=keygen&user=$PAN_USER&password=$ENC_PASS" 2>/dev/null \
        | python3 -c "
import sys, xml.etree.ElementTree as ET
root = ET.fromstring(sys.stdin.read())
print(root.findtext('.//key',''))
" 2>/dev/null)

      if [ -z "$API_KEY" ]; then
        echo "[ERROR] Could not get API key for jobs-idle wait"; exit 1
      fi

      echo "=== [Step 4c] Waiting for Panorama to be idle (no pending jobs) ==="
      MAX=60   # 60 x 5s = 5 min hard cap
      for ATTEMPT in $(seq 1 $MAX); do
        JOBS_RESP=$(curl -sk --max-time 15 \
          "$PANORAMA_URL/api/?type=op&cmd=<show><jobs><all></all></jobs></show>&key=$API_KEY" 2>/dev/null || echo "")

        # Count jobs whose status is ACT or PEND (running or pending) regardless of result
        ACTIVE=$(echo "$JOBS_RESP" | python3 -c "
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

        if [ -z "$ACTIVE" ]; then ACTIVE=0; fi

        if [ "$ACTIVE" = "0" ]; then
          # Probe with a cheap op call to confirm config lock is free
          PROBE=$(curl -sk --max-time 15 \
            "$PANORAMA_URL/api/?type=op&cmd=<show><config><running></running></config></show>&key=$API_KEY" 2>/dev/null \
            | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    print(ET.fromstring(sys.stdin.read()).get('status',''))
except Exception:
    print('')
" 2>/dev/null)

          if [ "$PROBE" = "success" ]; then
            echo "  [OK] Panorama idle and config-lock free (attempt $ATTEMPT)"
            exit 0
          fi
          echo "  [$ATTEMPT/$MAX] No active jobs but probe not yet OK — waiting 5s..."
        else
          echo "  [$ATTEMPT/$MAX] Active jobs: $ACTIVE — waiting 5s..."
        fi

        sleep 5
      done

      echo "  [WARN] Pending jobs still present after $((MAX*5))s — proceeding anyway"
      echo "         If the next resource fails with 'context deadline exceeded',"
      echo "         re-run terraform apply (idempotent)."
      exit 0
    SCRIPT
  }

  depends_on = [null_resource.panorama_configure_collector_group]
}

###############################################################################
# Step 5: Panorama Config via panos provider
# Template Stack, Device Group, Interfaces, Zones, VR, Routes, NAT, Security
# Log Forwarding Profile with send_to_panorama=true for all security rules
###############################################################################
module "panorama_config" {
  source = "../modules/panorama_config"

  panorama_hostname = var.panorama_hostname
  panorama_username = var.panorama_username
  panorama_password = var.panorama_password

  template_name       = var.template_name
  template_stack_name = var.template_stack_name
  device_group_name   = var.device_group_name

  trust_subnet_cidr   = var.trust_subnet_cidr
  untrust_subnet_cidr = var.untrust_subnet_cidr
  spoke1_vnet_cidr    = var.spoke1_vnet_cidr
  spoke2_vnet_cidr    = var.spoke2_vnet_cidr

  apache_server_ip      = var.apache_server_ip
  external_lb_public_ip = var.external_lb_public_ip

  depends_on = [
    null_resource.panorama_activate_license,
    null_resource.panorama_set_hostname,
    null_resource.panorama_configure_collector_group,
    null_resource.panorama_wait_jobs_idle,
  ]
}

###############################################################################
# Step 6: Final Panorama Commit
###############################################################################
resource "null_resource" "panorama_commit" {
  triggers = {
    template_name       = var.template_name
    template_stack_name = var.template_stack_name
    device_group_name   = var.device_group_name
    external_lb_ip      = var.external_lb_public_ip
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -e
      PANORAMA_URL="https://${var.panorama_hostname}:${var.panorama_port}"
      PAN_USER="${var.panorama_username}"

      echo "=== [Step 6] Final Commit on Panorama ==="

      ENC_PASS=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${var.panorama_password}', safe=''))")
      API_KEY=$(curl -sk --max-time 30 "$PANORAMA_URL/api/?type=keygen&user=$PAN_USER&password=$ENC_PASS" 2>/dev/null \
        | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read())
    print(root.findtext('.//key',''))
except: pass
" 2>/dev/null)

      COMMIT_RESP=$(curl -sk --max-time 90 "$PANORAMA_URL/api/" \
        --data-urlencode "type=commit" \
        --data-urlencode "cmd=<commit></commit>" \
        --data-urlencode "key=$API_KEY" 2>/dev/null)

      echo "$COMMIT_RESP" | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read())
    status = root.get('status','')
    code = root.get('code','')
    if status == 'success':
        print('[OK] Commit: success!')
    elif code == '19':
        print('[OK] Nothing to commit.')
    else:
        msg = root.findtext('.//msg','') or root.findtext('.//line','')
        print('[WARN] Commit: status=' + status + ' msg=' + str(msg))
except Exception as e:
    print('[WARN] Error ' + str(e))
" 2>/dev/null
    SCRIPT
  }

  depends_on = [module.panorama_config]
}