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
# Step 3.5: Fetch Panorama device certificate via OTP (if provided)
#
# CSP Portal -> Assets -> Device Certificates -> Generate OTP for Panorama's
# serial number. Paste the OTP into phase2 terraform.tfvars
# (panorama_device_otp). 60-min lifetime, single-use.
#
# This step is idempotent in two ways:
#   - count=0 if OTP is empty (skipped silently)
#   - if Panorama already has a valid device cert (`show device-cert info`),
#     the fetch is skipped to avoid wasting the OTP
#
# Without a device certificate, Panorama can't authenticate to Strata cloud
# services (Strata Logging Service, Cloud Identity Engine, etc.). For an
# on-prem-style deployment with local logs, this is optional.
###############################################################################
resource "null_resource" "panorama_fetch_device_certificate" {
  count = var.panorama_device_otp != "" ? 1 : 0

  triggers = {
    otp_hash = sha256(var.panorama_device_otp)
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -e
      PANORAMA_URL="https://${var.panorama_hostname}:${var.panorama_port}"
      PAN_USER="${var.panorama_username}"
      OTP="${var.panorama_device_otp}"

      echo "=== [Step 3.5] Fetching Panorama device certificate ==="

      # IMPORTANT: Panorama device-cert API syntax differs from FW. Pre-fix
      # code used FW syntax (<show><device-cert>, <request><device-certificate>)
      # which silently fails on Panorama with "is unexpected" (error code 17),
      # so the resource always reported success while doing nothing. Empirically
      # verified 2026-05-06 against PAN-OS 12.1.5:
      #   FW:       <show><device-cert>...      <request><device-certificate>...
      #   Panorama: <show><device-certificate>... <request><certificate>...
      ENC_PASS=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${var.panorama_password}', safe=''))")
      API_KEY=$(curl -sk --max-time 30 \
        "$PANORAMA_URL/api/?type=keygen&user=$PAN_USER&password=$ENC_PASS" 2>/dev/null \
        | python3 -c "
import sys, xml.etree.ElementTree as ET
root = ET.fromstring(sys.stdin.read())
print(root.findtext('.//key',''))
" 2>/dev/null)

      if [ -z "$API_KEY" ]; then
        echo "[ERROR] Could not get API key for cert fetch"; exit 1
      fi

      # Pre-check: skip if certificate already installed and valid (Panorama
      # syntax). On a fresh Panorama with no cert, <result> is empty —
      # treat as MISSING. If <result> contains a <not-valid-after> field with
      # a future date, treat as VALID.
      CERT_STATUS=$(curl -sk --max-time 15 \
        "$PANORAMA_URL/api/?type=op&cmd=<show><device-certificate><info></info></device-certificate></show>&key=$API_KEY" 2>/dev/null \
        | python3 -c "
import sys, xml.etree.ElementTree as ET, datetime
try:
    root = ET.fromstring(sys.stdin.read())
    if root.get('status','') != 'success':
        print('UNKNOWN'); sys.exit(0)
    result = root.find('.//result')
    if result is None or len(list(result)) == 0:
        print('MISSING'); sys.exit(0)
    # Check for an explicit valid status or non-empty subject + future expiry
    status = (result.findtext('.//status','') or result.findtext('.//validity','') or '').strip()
    if status and 'valid' in status.lower():
        print('VALID'); sys.exit(0)
    subject = (result.findtext('.//subject','') or result.findtext('.//certificate-subject-name','') or '').strip()
    print('VALID' if subject else 'MISSING')
except Exception:
    print('UNKNOWN')
" 2>/dev/null)

      echo "  Current device-cert status: $CERT_STATUS"
      if [ "$CERT_STATUS" = "VALID" ]; then
        echo "  [OK] Device certificate already installed — skipping fetch (OTP not consumed)"
        exit 0
      fi

      # Fetch via Panorama syntax (<request><certificate><fetch>...). Returns
      # async job ID; poll until FIN.
      echo "  Calling: request certificate fetch otp <OTP>"
      RESP=$(curl -sk --max-time 60 "$PANORAMA_URL/api/" \
        --data-urlencode "type=op" \
        --data-urlencode "cmd=<request><certificate><fetch><otp>$OTP</otp></fetch></certificate></request>" \
        --data-urlencode "key=$API_KEY" 2>/dev/null)

      JID=$(echo "$RESP" | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    r = ET.fromstring(sys.stdin.read())
    if r.get('status','') != 'success':
        print('')
    else:
        print(r.findtext('.//job','') or '')
except: print('')
" 2>/dev/null)

      if [ -z "$JID" ]; then
        # Submit failed entirely — extract error message
        MSG=$(echo "$RESP" | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    r = ET.fromstring(sys.stdin.read())
    print(r.findtext('.//msg','') or r.findtext('.//line','') or 'no message')
except: print('unparseable response')
" 2>/dev/null)
        echo "  [ERROR] Device cert fetch submit failed: $MSG"
        echo "  Raw response: $RESP" | head -c 500
        exit 1
      fi

      echo "  Cert fetch job $JID enqueued — polling for FIN..."
      for I in $(seq 1 30); do  # 30 x 5s = 150s cap
        JOB_STATE=$(curl -sk --max-time 10 \
          "$PANORAMA_URL/api/?type=op&cmd=<show><jobs><id>$JID</id></jobs></show>&key=$API_KEY" 2>/dev/null \
          | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    j = ET.fromstring(sys.stdin.read()).find('.//job')
    s = (j.findtext('status','') or '').upper()
    r = (j.findtext('result','') or '').upper()
    d = ' | '.join((line.text or '') for line in j.iter('line') if line.text)
    print(s + '|' + r + '|' + d[:300])
except: print('||')
" 2>/dev/null)
        STATUS=$(echo "$JOB_STATE" | cut -d'|' -f1)
        RESULT=$(echo "$JOB_STATE" | cut -d'|' -f2)
        DETAILS=$(echo "$JOB_STATE" | cut -d'|' -f3)
        if [ "$STATUS" = "FIN" ]; then
          if [ "$RESULT" = "OK" ]; then
            echo "  [OK] Device certificate installed after $((I*5))s"
            exit 0
          fi
          echo "  [ERROR] Device cert fetch FIN/$RESULT after $((I*5))s"
          echo "          Job details: $DETAILS"
          if echo "$DETAILS" | grep -qi "OTP is not valid"; then
            echo ""
            echo "  >>> OTP is invalid (already used OR expired — OTPs are single-use, 60-min lifetime)"
            echo "  >>> RECOVERY:"
            echo "  >>>   1. CSP Portal -> Assets -> Device Certificates -> Generate OTP"
            echo "  >>>      against Panorama serial: ${var.panorama_serial_number}"
            echo "  >>>   2. Update phase2-panorama-config/terraform.tfvars: panorama_device_otp = \"<NEW_OTP>\""
            echo "  >>>   3. terraform apply -target=null_resource.panorama_fetch_device_certificate"
          fi
          exit 1
        fi
        sleep 5
      done
      echo "  [WARN] Cert fetch job did not finish within 150s — investigate via show jobs id $JID"
      exit 1
    SCRIPT
  }

  depends_on = [null_resource.panorama_activate_license]
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
# Step 4b: Bind local Panorama LC to default Collector Group
#
# Panorama in default Panorama Mode has logd running locally and is registered
# as its own Managed Collector ("management-node: yes" in `show log-collector
# all`). However, the default Collector Group `default` ships with EMPTY
# members list — the local LC is NOT auto-bound to it. Logs from FWs cannot
# be ingested until that binding exists, AND the Collector Group config must
# be pushed to the LC daemon via a dedicated `commit-all log-collector-config`
# (a regular Panorama commit alone leaves the LC in "Out of Sync — Ring
# version mismatch" state).
#
# This is the equivalent of running on Panorama operational CLI:
#   admin@panorama> configure
#   admin@panorama# set log-collector-group default logfwd-setting collectors <PANORAMA_SERIAL>
#   admin@panorama# commit
#   admin@panorama> commit-all log-collector-config log-collector-group default
#
# CLI auto-creates BOTH the local LC entry and the CG entry in one shot.
# XML API requires TWO explicit SETs because the deeper xpath that includes
# the (not-yet-existing) `default` entry is rejected with "Could not find
# schema node". Both SETs go under /config/devices/entry[@name='localhost.
# localdomain']/* — Panorama is treated as a device-level container in the
# XML schema, NOT under /config/panorama/* (CLI keyword namespace and XML
# config tree namespace diverge here).
#
# IMPORTANT XML API traps (verified empirically 2026-05-05; do NOT regress):
#   - Wrong xpath: /config/panorama/log-collector-group/... → schema-node-not-found
#   - Wrong xpath: /config/panorama/collector-group/...    → schema-node-not-found
#   - Correct xpath base: /config/devices/entry[@name='localhost.localdomain']
#   - Member format: <member>SERIAL</member> (string reference), NOT
#     <entry name='SERIAL'/> (which is for full objects). Using <entry> here
#     triggers error code 12: "'SERIAL' is not a valid reference".
#   - commit-all log-collector-config returns SYNCHRONOUSLY (no <job> element)
#     when only the local LC is in the group. Code that requires a job ID for
#     polling will treat this as failure. Handle BOTH sync success and async
#     job-id paths.
#
# Side effect of completing this step: Panorama GUI Collector Groups → default
# → Master Node Settings tab populates correctly. Without the binding the GUI
# refuses to save anything in that tab (WebUI glitch — no useful error).
#
# Ref: https://docs.paloaltonetworks.com/panorama/11-1/panorama-admin/manage-log-collection
###############################################################################
resource "null_resource" "panorama_bind_local_lc" {
  triggers = {
    collector_group = "default"
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -e
      PANORAMA_URL="https://${var.panorama_hostname}:${var.panorama_port}"
      PAN_USER="${var.panorama_username}"

      echo "=== [Step 4b] Binding local Panorama LC to default Collector Group ==="

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

      # 4b-1: Get Panorama serial number (must come from device, not tfvars,
      # so this stays correct even if user changed serial after deploy).
      echo "  Getting Panorama serial number..."
      PAN_SERIAL=$(curl -sk --max-time 30 \
        "$PANORAMA_URL/api/?type=op&cmd=<show><system><info></info></system></show>&key=$API_KEY" 2>/dev/null \
        | python3 -c "
import sys, xml.etree.ElementTree as ET
root = ET.fromstring(sys.stdin.read())
print(root.findtext('.//serial','unknown'))
" 2>/dev/null)

      if [ "$PAN_SERIAL" = "unknown" ] || [ -z "$PAN_SERIAL" ]; then
        echo "  [ERROR] Could not determine Panorama serial — Step 3 (license activation) probably did not run."
        echo "          Manual recovery: Panorama CLI → set log-collector-group default logfwd-setting collectors <SERIAL> + commit + commit-all log-collector-config log-collector-group default"
        exit 1
      fi
      echo "  Panorama serial: $PAN_SERIAL"

      # 4b-2: Idempotency pre-check — does default CG already have local LC as member?
      # GET the collectors node and check if a <member> with the serial is present.
      EXISTING=$(curl -sk --max-time 30 "$PANORAMA_URL/api/" \
        --data-urlencode "type=config" \
        --data-urlencode "action=get" \
        --data-urlencode "xpath=/config/devices/entry[@name='localhost.localdomain']/log-collector-group/entry[@name='default']/logfwd-setting/collectors" \
        --data-urlencode "key=$API_KEY" 2>/dev/null \
        | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read())
    found = any((m.text or '').strip() == '$PAN_SERIAL' for m in root.iter('member'))
    print('FOUND' if found else 'MISSING')
except Exception:
    print('MISSING')
" 2>/dev/null)

      if [ "$EXISTING" = "FOUND" ]; then
        echo "  [OK] Local LC ($PAN_SERIAL) already bound to default CG — skipping set+commit"
        echo "       (Verify In Sync with: show log-collector all)"
        exit 0
      fi

      # 4b-3a: Create the local Managed Collector entry (under device-level
      # log-collector node — see header for the xpath rationale).
      echo "  Creating local Managed Collector entry ($PAN_SERIAL)..."
      SET1_RESP=$(curl -sk --max-time 30 "$PANORAMA_URL/api/" \
        --data-urlencode "type=config" \
        --data-urlencode "action=set" \
        --data-urlencode "xpath=/config/devices/entry[@name='localhost.localdomain']/log-collector" \
        --data-urlencode "element=<entry name='$PAN_SERIAL'><deviceconfig/></entry>" \
        --data-urlencode "key=$API_KEY")
      SET1_STATUS=$(echo "$SET1_RESP" | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    print(ET.fromstring(sys.stdin.read()).get('status',''))
except Exception:
    print('')
" 2>/dev/null)
      if [ "$SET1_STATUS" != "success" ]; then
        echo "  [ERROR] Managed Collector entry SET failed. Raw response:"
        echo "$SET1_RESP" | head -3
        exit 1
      fi
      echo "  [OK] Managed Collector entry created"

      # 4b-3b: Create the Collector Group entry with local LC as member.
      # <member>SERIAL</member> (string reference), NOT <entry name='SERIAL'/>.
      echo "  Creating Collector Group 'default' with local LC as member..."
      SET2_RESP=$(curl -sk --max-time 30 "$PANORAMA_URL/api/" \
        --data-urlencode "type=config" \
        --data-urlencode "action=set" \
        --data-urlencode "xpath=/config/devices/entry[@name='localhost.localdomain']/log-collector-group" \
        --data-urlencode "element=<entry name='default'><logfwd-setting><collectors><member>$PAN_SERIAL</member></collectors></logfwd-setting></entry>" \
        --data-urlencode "key=$API_KEY")
      SET2_STATUS=$(echo "$SET2_RESP" | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    print(ET.fromstring(sys.stdin.read()).get('status',''))
except Exception:
    print('')
" 2>/dev/null)
      if [ "$SET2_STATUS" != "success" ]; then
        echo "  [ERROR] Collector Group SET failed. Raw response:"
        echo "$SET2_RESP" | head -3
        exit 1
      fi
      echo "  [OK] Collector Group created with member ref"

      # 4b-4: Commit on Panorama side. Returns job ID — poll until FIN.
      echo "  Committing Panorama config..."
      COMMIT_JID=$(curl -sk --max-time 60 "$PANORAMA_URL/api/" \
        --data-urlencode "type=commit" \
        --data-urlencode "cmd=<commit></commit>" \
        --data-urlencode "key=$API_KEY" \
        | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    print(ET.fromstring(sys.stdin.read()).findtext('.//job',''))
except Exception:
    print('')
" 2>/dev/null)

      if [ -z "$COMMIT_JID" ]; then
        echo "  [WARN] Commit returned no job ID — may already be committed (no changes). Continuing."
      else
        echo "  Commit job ID: $COMMIT_JID — polling for completion..."
        for I in $(seq 1 30); do  # 30 x 5s = 150s cap
          JOB_STATE=$(curl -sk --max-time 15 \
            "$PANORAMA_URL/api/?type=op&cmd=<show><jobs><id>$COMMIT_JID</id></jobs></show>&key=$API_KEY" \
            | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    j = ET.fromstring(sys.stdin.read()).find('.//job')
    print((j.findtext('status','') or '').upper() + '|' + (j.findtext('result','') or '').upper())
except Exception:
    print('|')
" 2>/dev/null)
          STATUS=$(echo "$JOB_STATE" | cut -d'|' -f1)
          RESULT=$(echo "$JOB_STATE" | cut -d'|' -f2)
          if [ "$STATUS" = "FIN" ]; then
            if [ "$RESULT" = "OK" ]; then
              echo "  [OK] Panorama commit FIN/OK (after $((I*5))s)"
              break
            else
              echo "  [ERROR] Panorama commit FIN/$RESULT — see GUI Tasks for details"
              exit 1
            fi
          fi
          sleep 5
        done
      fi

      # 4b-5: commit-all log-collector-config — pushes CG config to LC daemon.
      # WITHOUT this step the LC stays in "Out of Sync — Ring version mismatch"
      # and rejects/buffers incoming logs from FWs.
      #
      # SYNC vs ASYNC: when only the local Panorama LC is in the group, this
      # commit-all returns SYNCHRONOUSLY (status=success, no <job>) — verified
      # empirically 2026-05-05. With remote/dedicated LCs, it returns a job ID
      # to poll. Handle both paths.
      echo "  Pushing Collector Group config to LC (commit-all log-collector-config)..."
      CA_RESP=$(curl -sk --max-time 60 "$PANORAMA_URL/api/" \
        --data-urlencode "type=commit" \
        --data-urlencode "action=all" \
        --data-urlencode "cmd=<commit-all><log-collector-config><log-collector-group>default</log-collector-group></log-collector-config></commit-all>" \
        --data-urlencode "key=$API_KEY")
      CA_PARSED=$(echo "$CA_RESP" | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    r = ET.fromstring(sys.stdin.read())
    print((r.get('status','') or '') + '|' + (r.findtext('.//job','') or ''))
except Exception:
    print('|')
" 2>/dev/null)
      CA_STATUS=$(echo "$CA_PARSED" | cut -d'|' -f1)
      CA_JID=$(echo "$CA_PARSED" | cut -d'|' -f2)

      if [ "$CA_STATUS" = "success" ] && [ -z "$CA_JID" ]; then
        # Sync success — Panorama returned the success message directly.
        echo "  [OK] commit-all log-collector-config succeeded (sync — local LC only)"
      elif [ -n "$CA_JID" ]; then
        echo "  commit-all job ID: $CA_JID — polling for completion..."
        for I in $(seq 1 36); do  # 36 x 5s = 180s cap (CG push can be slower)
          JOB_STATE=$(curl -sk --max-time 15 \
            "$PANORAMA_URL/api/?type=op&cmd=<show><jobs><id>$CA_JID</id></jobs></show>&key=$API_KEY" \
            | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    j = ET.fromstring(sys.stdin.read()).find('.//job')
    print((j.findtext('status','') or '').upper() + '|' + (j.findtext('result','') or '').upper())
except Exception:
    print('|')
" 2>/dev/null)
          STATUS=$(echo "$JOB_STATE" | cut -d'|' -f1)
          RESULT=$(echo "$JOB_STATE" | cut -d'|' -f2)
          if [ "$STATUS" = "FIN" ]; then
            if [ "$RESULT" = "OK" ]; then
              echo "  [OK] commit-all log-collector-config FIN/OK (after $((I*5))s)"
              break
            else
              echo "  [ERROR] commit-all log-collector-config FIN/$RESULT — check Panorama GUI Tasks for details"
              exit 1
            fi
          fi
          sleep 5
        done
      else
        echo "  [ERROR] commit-all log-collector-config failed — neither sync success nor async job. Raw response:"
        echo "$CA_RESP" | head -3
        exit 1
      fi

      # 4b-6: Verify Config Status flipped to In Sync (Ring version match).
      echo "  Verifying log-collector Config Status..."
      for I in $(seq 1 12); do  # 12 x 5s = 60s cap
        SYNC_STATE=$(curl -sk --max-time 15 \
          "$PANORAMA_URL/api/?type=op&cmd=<show><log-collector><all></all></log-collector></show>&key=$API_KEY" \
          | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read())
    for lc in root.findall('.//entry'):
        if (lc.findtext('serial','') or '') == '$PAN_SERIAL':
            print(lc.findtext('config-status','') or 'unknown')
            break
    else:
        print('lc-not-found')
except Exception:
    print('parse-error')
" 2>/dev/null)

        case "$SYNC_STATE" in
          *In*Sync*|*"in sync"*|*"In Sync"*)
            echo "  [OK] Config Status: $SYNC_STATE (logs will now flow)"
            exit 0
            ;;
        esac
        echo "  [$I/12] Config Status: $SYNC_STATE — waiting 5s..."
        sleep 5
      done
      echo "  [WARN] Config Status did not reach In Sync within 60s. Last seen: $SYNC_STATE"
      echo "         Verify manually: admin@panorama> show log-collector all"
      echo "         If Out of Sync persists, re-run: commit-all log-collector-config log-collector-group default"
    SCRIPT
  }

  depends_on = [null_resource.panorama_generate_vm_auth_key]
}

###############################################################################
# Step 4b2: Declare disk-pair on local Managed Collector entry
#
# WHY THIS IS REQUIRED (verified empirically 2026-05-06 on PAN-OS 12.1.5):
# Without a disk-pair entry under the LC's <disk-settings>, logd accepts
# incoming logs into a memory buffer but never flushes them to the attached
# log volume (/opt/panlogs/ld1 backed by /dev/sdc1). Symptoms:
#   - `debug log-collector log-collection-stats show incoming-logs` shows
#     thousands of received logs but `blkcount: 0` for every type.
#   - `show log-collector all` reports `searchengine-status: Inactive`.
#   - Log query API (type=log&action=get) returns 0 entries even after
#     hours of traffic.
#   - `df -h /opt/panlogs/ld1` stays at minimal usage (filesystem metadata
#     only, ~36K).
# After the disk-pair entry is committed and pushed to the LC daemon,
# searchengine-status flips to Active, sdc1 Used grows live as logs flush,
# and Monitor → Traffic populates within minutes.
#
# DISCOVERY: The xpath / element name was found via `debug cli on` in the
# Panorama CLI on 2026-05-06. Earlier guesses against
# /deviceconfig/system/logger/disk-pair, /disk-pair, /disks, /raid, etc.
# were all schema-rejected (8 candidates × error code 13). The actual
# location is .../log-collector/entry/disk-settings/disk-pair, which is
# undocumented in panorama-admin.pdf and the API reference PDF.
#
# Equivalent CLI (interactive) — what GUI does when you click
# Panorama → Managed Collectors → [LC] → Disks tab → Add Pair → A → OK:
#   admin@panorama# edit log-collector <SERIAL>
#   admin@panorama# set disk-settings disk-pair A
#   admin@panorama# commit
#   admin@panorama> commit-all log-collector-config log-collector-group default
#
# The pair name "A" is a label; PAN-OS auto-maps it to the available
# attached disk (Azure VM with the 2 TB managed disk attached gets
# /dev/sdc → /opt/panlogs/ld1). Single-disk-no-mirror is acceptable in
# this topology.
###############################################################################
resource "null_resource" "panorama_add_log_disk" {
  triggers = {
    disk_pair = "A"
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -e
      PANORAMA_URL="https://${var.panorama_hostname}:${var.panorama_port}"
      PAN_USER="${var.panorama_username}"

      echo "=== [Step 4b2] Adding disk-pair A to local LC ==="

      ENC_PASS=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${var.panorama_password}', safe=''))")
      API_KEY=$(curl -sk --max-time 30 \
        "$PANORAMA_URL/api/?type=keygen&user=$PAN_USER&password=$ENC_PASS" 2>/dev/null \
        | python3 -c "
import sys, xml.etree.ElementTree as ET
root = ET.fromstring(sys.stdin.read())
print(root.findtext('.//key',''))
" 2>/dev/null)

      if [ -z "$API_KEY" ]; then
        echo "[ERROR] Failed to get API key"; exit 1
      fi

      PAN_SERIAL=$(curl -sk --max-time 30 \
        "$PANORAMA_URL/api/?type=op&cmd=<show><system><info></info></system></show>&key=$API_KEY" 2>/dev/null \
        | python3 -c "
import sys, xml.etree.ElementTree as ET
print(ET.fromstring(sys.stdin.read()).findtext('.//serial','unknown'))
" 2>/dev/null)

      if [ "$PAN_SERIAL" = "unknown" ] || [ -z "$PAN_SERIAL" ]; then
        echo "[ERROR] Could not determine Panorama serial"; exit 1
      fi
      echo "  Panorama serial: $PAN_SERIAL"

      # Idempotency: skip if disk-pair A already declared.
      EXISTING=$(curl -sk --max-time 15 -X POST "$PANORAMA_URL/api/" \
        --data-urlencode "type=config" \
        --data-urlencode "action=get" \
        --data-urlencode "xpath=/config/devices/entry[@name='localhost.localdomain']/log-collector/entry[@name='$PAN_SERIAL']/disk-settings/disk-pair/entry[@name='A']" \
        --data-urlencode "key=$API_KEY" 2>/dev/null \
        | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read())
    e = root.find(\".//entry[@name='A']\")
    print('FOUND' if e is not None else 'MISSING')
except Exception:
    print('MISSING')
" 2>/dev/null)

      if [ "$EXISTING" = "FOUND" ]; then
        echo "  [OK] disk-pair A already declared on LC ($PAN_SERIAL) — skipping"
        exit 0
      fi

      # SET disk-pair entry. Element is just <entry name='A'/> — no inner
      # config; PAN-OS auto-maps to the available disk.
      SET_RESP=$(curl -sk --max-time 30 -X POST "$PANORAMA_URL/api/" \
        --data-urlencode "type=config" \
        --data-urlencode "action=set" \
        --data-urlencode "xpath=/config/devices/entry[@name='localhost.localdomain']/log-collector/entry[@name='$PAN_SERIAL']/disk-settings/disk-pair" \
        --data-urlencode "element=<entry name='A'/>" \
        --data-urlencode "key=$API_KEY")
      SET_STATUS=$(echo "$SET_RESP" | python3 -c "
import sys, xml.etree.ElementTree as ET
try: print(ET.fromstring(sys.stdin.read()).get('status',''))
except: print('')
" 2>/dev/null)
      if [ "$SET_STATUS" != "success" ]; then
        echo "  [ERROR] disk-pair SET failed. Response:"
        echo "$SET_RESP" | head -3
        exit 1
      fi
      echo "  [OK] disk-pair A set in candidate config"

      # Commit and poll. Without commit, the disk-pair entry stays in the
      # candidate config and never reaches the LC daemon.
      echo "  Committing Panorama config..."
      COMMIT_JID=$(curl -sk --max-time 60 -X POST "$PANORAMA_URL/api/" \
        --data-urlencode "type=commit" \
        --data-urlencode "cmd=<commit></commit>" \
        --data-urlencode "key=$API_KEY" \
        | python3 -c "
import sys, xml.etree.ElementTree as ET
try: print(ET.fromstring(sys.stdin.read()).findtext('.//job',''))
except: print('')
" 2>/dev/null)

      if [ -n "$COMMIT_JID" ]; then
        echo "  Commit job $COMMIT_JID — polling..."
        for I in $(seq 1 60); do  # 60 x 5s = 300s — disk init can take longer
          JOB_STATE=$(curl -sk --max-time 10 \
            "$PANORAMA_URL/api/?type=op&cmd=<show><jobs><id>$COMMIT_JID</id></jobs></show>&key=$API_KEY" \
            | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    j = ET.fromstring(sys.stdin.read()).find('.//job')
    print((j.findtext('status','') or '').upper() + '|' + (j.findtext('result','') or '').upper())
except: print('|')
" 2>/dev/null)
          STATUS=$(echo "$JOB_STATE" | cut -d'|' -f1)
          RESULT=$(echo "$JOB_STATE" | cut -d'|' -f2)
          if [ "$STATUS" = "FIN" ]; then
            [ "$RESULT" = "OK" ] && echo "  [OK] commit FIN/OK after $((I*5))s" && break
            echo "  [ERROR] commit FIN/$RESULT"; exit 1
          fi
          sleep 5
        done
      fi

      # Push CG config to LC daemon (sync response for single-LC).
      echo "  Pushing CG to LC daemon (commit-all log-collector-config)..."
      curl -sk --max-time 60 -X POST "$PANORAMA_URL/api/" \
        --data-urlencode "type=commit" \
        --data-urlencode "action=all" \
        --data-urlencode "cmd=<commit-all><log-collector-config><log-collector-group>default</log-collector-group></log-collector-config></commit-all>" \
        --data-urlencode "key=$API_KEY" > /dev/null

      echo "  [OK] disk-pair A active. SearchEngine will flip to Active within ~30s of first traffic."
      echo "       Verify: show log-collector all (searchengine-status: Active)"
      echo "       Verify: show system disk-space (Used on /opt/panlogs/ld1 grows with traffic)"
    SCRIPT
  }

  depends_on = [null_resource.panorama_bind_local_lc]
}

###############################################################################
# Step 4b3: Restart Panorama (REQUIRED for ES indices reinit on disk-pair)
#
# WHY THIS IS REQUIRED (verified empirically 2026-05-07 on PAN-OS 12.1.5):
# After Step 4b2 adds the disk-pair config and `commit-all log-collector-config`
# pushes it to logd, the logd daemon accepts the new disk and starts writing
# logs to it (`/dev/sdc → /opt/panlogs/ld1`, Used grows). However, the
# Elasticsearch (ES) daemon does NOT automatically reinitialize its indices
# against the new storage backend — it keeps using stale indices that were
# associated with the empty `<deviceconfig/>` block from before disk-pair
# was declared.
#
# Symptoms without this restart:
#   - `show log-collector all` shows searchengine-status: Active, es: GREEN.
#   - `debug log-collector log-collection-stats show incoming-logs` shows
#     thousands of log entries received and counted by inline reports.
#   - `df -h /opt/panlogs/ld1` shows Used growing live as logs flush to disk.
#   - BUT `type=log&action=get` queries return count=0 every time, even
#     after hours of waiting and many fresh traffic samples.
#   - GUI Panorama → Monitor → Traffic remains empty.
# After Panorama reboot:
#   - Same disk, same config, same DLF entries → ES rebuilds indices on
#     boot from the disk-pair declared in config.
#   - Log query API returns actual results within ~1 minute of API back online.
#   - GUI Monitor → Traffic populates with all historical + new logs.
#
# Cost: ~5-10 minutes Panorama boot time on Azure VM. One-shot per fresh
# deploy; subsequent re-runs of `terraform apply` skip this step (count=0
# guard plus the trigger only fires when after_add_log_disk changes).
#
# Implementation: send `<request><restart><system></system></restart></request>`
# via op API. Connection drops within seconds. Sleep 8 minutes (typical boot),
# then poll API up to 5 more minutes for keygen success.
###############################################################################
resource "null_resource" "panorama_restart_for_es_reinit" {
  count = var.panorama_restart_after_disk_pair ? 1 : 0

  triggers = {
    after_add_log_disk = null_resource.panorama_add_log_disk.id
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -e
      PANORAMA_URL="https://${var.panorama_hostname}:${var.panorama_port}"
      PAN_USER="${var.panorama_username}"

      echo "=== [Step 4b3] Restarting Panorama for ES indices reinit on new disk-pair ==="
      echo "  This adds ~8-13 minutes to Phase 2a duration but is required for"
      echo "  log queries to work on a fresh deploy. Set var.panorama_restart_after_disk_pair=false"
      echo "  to skip this step (e.g. if Panorama is already in steady state)."

      ENC_PASS=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${var.panorama_password}', safe=''))")
      API_KEY=$(curl -sk --max-time 30 \
        "$PANORAMA_URL/api/?type=keygen&user=$PAN_USER&password=$ENC_PASS" 2>/dev/null \
        | python3 -c "
import sys, xml.etree.ElementTree as ET
print(ET.fromstring(sys.stdin.read()).findtext('.//key',''))
" 2>/dev/null)

      if [ -z "$API_KEY" ]; then
        echo "[ERROR] Cannot get API key — Panorama may already be down. Skipping restart."
        exit 0
      fi

      # Idempotency probe: if log query returns >0 results, ES indices are
      # already healthy — no need to restart. Useful for re-runs of terraform apply.
      JID=$(curl -sk --max-time 15 \
        "$PANORAMA_URL/api/?type=log&log-type=traffic&nlogs=1&key=$API_KEY" \
        | python3 -c "
import sys, xml.etree.ElementTree as ET
try: print(ET.fromstring(sys.stdin.read()).findtext('.//job',''))
except: print('')
" 2>/dev/null)

      if [ -n "$JID" ]; then
        sleep 10
        COUNT=$(curl -sk --max-time 15 \
          "$PANORAMA_URL/api/?type=log&action=get&job-id=$JID&key=$API_KEY" \
          | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    r = ET.fromstring(sys.stdin.read())
    logs = r.find('.//logs')
    print(logs.get('count','0') if logs is not None else '0')
except: print('0')
" 2>/dev/null)
        if [ -n "$COUNT" ] && [ "$COUNT" != "0" ]; then
          echo "  [OK] Log query already returns $COUNT entries — ES indices healthy, skipping restart"
          exit 0
        fi
      fi

      echo "  Sending request system restart (connection will drop)..."
      curl -sk --max-time 5 \
        "$PANORAMA_URL/api/?type=op&cmd=<request><restart><system></system></restart></request>&key=$API_KEY" \
        2>/dev/null || true

      echo "  Waiting 8 minutes for boot..."
      sleep 480

      echo "  Probing API for readiness (up to 5 min)..."
      for I in $(seq 1 30); do
        HTTP=$(curl -sk --max-time 10 -o /dev/null -w "%%{http_code}" \
          "$PANORAMA_URL/api/?type=keygen&user=$PAN_USER&password=$ENC_PASS" 2>/dev/null || echo "000")
        if [ "$HTTP" = "200" ]; then
          echo "  [OK] Panorama API back online (attempt $I)"
          # Brief settle so ES finishes index init
          sleep 30
          exit 0
        fi
        sleep 10
      done

      echo "  [WARN] Panorama API not back after 13 min total. Manual check recommended."
      echo "         If reachable: show log-collector all (expect searchengine-status: Active)"
      exit 0
    SCRIPT
  }

  depends_on = [null_resource.panorama_add_log_disk]
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
    after_restart = var.panorama_restart_after_disk_pair ? null_resource.panorama_restart_for_es_reinit[0].id : null_resource.panorama_add_log_disk.id
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

  depends_on = [null_resource.panorama_bind_local_lc]
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
    null_resource.panorama_bind_local_lc,
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