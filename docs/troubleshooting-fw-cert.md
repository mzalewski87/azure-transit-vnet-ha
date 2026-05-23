# Troubleshooting: FW not connecting to Panorama (device-cert fetch fail)

## Symptom

After a fresh deployment:

- `terraform apply` for Phase 1a + 1b succeeds without error
- Phase 2b script (`scripts/register-fw-panorama.sh`) registers FW serials
  in Panorama mgt-config + device-group + template-stack — SET commands all
  return success
- Phase 2b `commit-all` for template-stack and shared-policy comes back
  **FIN/FAIL** with per-device status `not connected` for every FW serial
- On Panorama: `show devices connected` returns 0 entries
- On Panorama: `show devices all` lists the serials but `connected=no`

On FW side (Bastion tunnel + API):

- `show system info` is healthy (license activated, serial assigned)
- `show system bootstrap status` shows every phase Successful
- `show panorama-status` reports:
  ```
  Panorama Server 1 : 10.255.0.4
      Connected     : no
      HA state      : disconnected
  ```
- `show device-certificate status` reports:
  ```
  status=failure
  msg=Failed to fetch device certificate
  ```
- `show config /config/devices/entry[@name='localhost.localdomain']/deviceconfig/system`
  has `panorama-server: 10.255.0.4` BUT NO `vm-series-auto-registration`
  node, even though init-cfg DID contain `vm-series-auto-registration-pin-id`
  and `vm-series-auto-registration-pin-value`
- System log shows GRPC errors:
  ```
  Failed to establish GRPC connection to ADNS service:
  fail to load local cert and key: tls: failed to find any PEM data in
  certificate input
  ```

## Root cause

PAN-OS 11+/12.x **requires a device certificate** for the FW to establish a
managed connection to Panorama. The cert is auto-fetched at first boot
using the `vm-series-auto-registration-pin-id` + `pin-value` shipped via
init-cfg. **The PIN has a 1 / 7 / 30-day TTL** assigned at generation time
on the CSP Portal — if you redeploy to a fresh Azure subscription using
PIN values from a previous deployment older than the TTL, PAN-OS silently
rejects the expired PIN (no error in bootstrap status; the
`vm-series-auto-registration` node simply doesn't get written), and the
cert fetch fails.

Without the cert: FW initiates connection to Panorama TCP/3978, TLS
handshake completes the lr-cms0-def (log receiver) channel, but the
cms-management channel — which requires mutual TLS with the device
cert — does not, and Panorama treats the FW as disconnected.

## Diagnosis (~30 s)

```bash
# Open Bastion tunnel to FW1 on port 44301 (replace ID with terraform output)
FW1_ID=$(cd /Users/mzalewski/TF/azure-transit-vnet-ha && terraform output -raw fw1_vm_id)
az network bastion tunnel --name bastion-management --resource-group rg-transit-hub \
  --target-resource-id "$FW1_ID" --resource-port 443 --port 44301 &
sleep 20

# Get API key + check device-cert status
FW1_URL="https://127.0.0.1:44301/api/"
ENC_PASS=$(python3 -c "import urllib.parse; print(urllib.parse.quote('YOUR_ADMIN_PASSWORD', safe=''))")
FW1_KEY=$(curl -sk "$FW1_URL?type=keygen&user=panadmin&password=$ENC_PASS" | python3 -c "import sys, xml.etree.ElementTree as ET; print(ET.fromstring(sys.stdin.read()).findtext('.//key',''))")

curl -sk "$FW1_URL?type=op&cmd=<show><device-certificate><status></status></device-certificate></show>&key=$FW1_KEY"
# status=failure → cert problem confirmed

curl -sk "$FW1_URL?type=op&cmd=<show><panorama-status></panorama-status></show>&key=$FW1_KEY"
# Connected: no → confirms the symptom
```

## Fix

### Step 1 — generate fresh PIN

1. <https://support.paloaltonetworks.com> → **Assets** → **Device
   Certificates** → **Generate Registration PIN**
2. TTL: 30 days (maximum)
3. Save **PIN ID** + **PIN Value**

### Step 2 — push the new PIN to running FWs via API

Without re-deploying the FW VMs (which would mean another 15 min wait),
apply the new PIN directly through the FW XML API:

```bash
NEW_PIN_ID="<paste here>"
NEW_PIN_VALUE="<paste here>"

# Open Bastion tunnels to BOTH FWs (separate terminal each, or & background)
FW1_ID=$(cd /Users/mzalewski/TF/azure-transit-vnet-ha && terraform output -raw fw1_vm_id)
FW2_ID=$(cd /Users/mzalewski/TF/azure-transit-vnet-ha && terraform output -raw fw2_vm_id)
az network bastion tunnel --name bastion-management --resource-group rg-transit-hub --target-resource-id "$FW1_ID" --resource-port 443 --port 44301 &
az network bastion tunnel --name bastion-management --resource-group rg-transit-hub --target-resource-id "$FW2_ID" --resource-port 443 --port 44302 &
sleep 20

for PORT in 44301 44302; do
  FW_URL="https://127.0.0.1:$PORT/api/"
  ENC_PASS=$(python3 -c "import urllib.parse; print(urllib.parse.quote('YOUR_ADMIN_PASSWORD', safe=''))")
  FW_KEY=$(curl -sk "$FW_URL?type=keygen&user=panadmin&password=$ENC_PASS" | python3 -c "import sys, xml.etree.ElementTree as ET; print(ET.fromstring(sys.stdin.read()).findtext('.//key',''))")

  echo "=== FW on port $PORT ==="
  # Set PIN into deviceconfig
  curl -sk "$FW_URL" \
    --data-urlencode "type=config" \
    --data-urlencode "action=set" \
    --data-urlencode "xpath=/config/devices/entry[@name='localhost.localdomain']/deviceconfig/system/vm-series-auto-registration" \
    --data-urlencode "element=<pin-id>$NEW_PIN_ID</pin-id><pin-value>$NEW_PIN_VALUE</pin-value>" \
    --data-urlencode "key=$FW_KEY"
  echo ""
  # Commit
  curl -sk "$FW_URL?type=commit&cmd=<commit></commit>&key=$FW_KEY"
  echo ""
  # Trigger cert fetch
  curl -sk "$FW_URL?type=op&cmd=<request><certificate><fetch></fetch></certificate></request>&key=$FW_KEY"
  echo ""
done

# Wait ~60 s, verify
sleep 60
for PORT in 44301 44302; do
  FW_URL="https://127.0.0.1:$PORT/api/"
  ENC_PASS=$(python3 -c "import urllib.parse; print(urllib.parse.quote('YOUR_ADMIN_PASSWORD', safe=''))")
  FW_KEY=$(curl -sk "$FW_URL?type=keygen&user=panadmin&password=$ENC_PASS" | python3 -c "import sys, xml.etree.ElementTree as ET; print(ET.fromstring(sys.stdin.read()).findtext('.//key',''))")
  echo "=== FW on port $PORT ==="
  curl -sk "$FW_URL?type=op&cmd=<show><device-certificate><status></status></device-certificate></show>&key=$FW_KEY"
  echo ""
  curl -sk "$FW_URL?type=op&cmd=<show><panorama-status></panorama-status></show>&key=$FW_KEY"
done
```

After cert is fetched (status=success, expires in ~365 days) and Panorama
connection establishes (Connected: yes), re-run Phase 2b commit-all:

```bash
bash scripts/register-fw-panorama.sh
```

It is idempotent — pre-checks on serial registration will skip already-done
steps, the commit-all will now succeed because FWs are connected.

### Step 3 — update tfvars so future deploys use the fresh PIN

```bash
# In terraform.tfvars (root):
fw_registration_pin_id    = "<NEW_PIN_ID>"
fw_registration_pin_value = "<NEW_PIN_VALUE>"
```

So that `terraform refresh` doesn't surface drift, and future redeploys
ship the fresh values in init-cfg.

## Prevention

Add the PIN-refresh step to your redeployment checklist between
"new Azure subscription" and "terraform apply". See
[README "Prerequisites > Refresh VM-Series Registration PIN"](../README.md#refresh-vm-series-registration-pin-per-redeployment-to-fresh-subscription).

## Related

- `~/.claude/projects/.../memory/device_certificate_flow.md` — Panorama OTP
  vs FW Registration PIN flow
- PANW reference: <https://docs.paloaltonetworks.com/vm-series/11-1/vm-series-deployment/about-the-vm-series-firewall/install-a-device-certificate-on-the-vm-series-firewall>
