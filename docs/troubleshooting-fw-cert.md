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

---

## Related issue: Panorama "Failed to update DB" when generating vm-auth-key

Discovered 2026-05-24 on a Panorama instance (PAN-OS 12.1.5) that had been
through several rounds of state modification (re-deploys, manual config
changes via XML API, terraform apply -replace cycles): `request authkey add`
— both via XML API and via SSH CLI — consistently returned:

```
Server error : Failed to add authkey. Failed to update DB.
```

Phase 2a (`null_resource.panorama_generate_vm_auth_key` in
`phase2-panorama-config/main.tf`) calls exactly this command. If you hit
this on Phase 2a, the script fails and FW bootstrap init-cfg won't carry a
valid vm-auth-key — even though the network registration succeeds, the
mutual cms-management TLS handshake to Panorama silently fails (LCS log
receiver subagent connects, cms-management does not), and `show devices
connected` on Panorama stays empty indefinitely.

**Diagnostic signature** (all four together):

- `show devices all` on Panorama lists FW serials but `connected=no`
- `show panorama-status` on each FW: `Connected: no`
- `show device-certificate status` on each FW: `status=success` (cert IS
  fetched — this is NOT a PIN problem)
- Panorama system log: `lcs agent on <SERIAL>-log-collection connected`
  (proves FW reaches Panorama on TCP/3978 — networking is fine, the
  failure is specifically in cms-management auth)
- Any `request authkey add ...` on Panorama: `Failed to update DB`

**Root cause:** internal authkey storage in Panorama 12.1.5 enters a
state where new entries cannot be written. No PANW-published fix.
Symptom NOT reproduced on a fresh Panorama VM — only on instances that
have undergone significant config churn.

**Workaround:** replace the Panorama VM and re-run Phase 2a.

```bash
# 1. terraform-replace Panorama (preserves state for rest of root module)
cd /path/to/azure-transit-vnet-ha
terraform apply -replace=module.panorama.azurerm_linux_virtual_machine.panorama \
  -target=module.panorama

# 2. Wait ~10 min for Panorama boot + license activation

# 3. Re-run Phase 2a (generates a fresh vm-auth-key, writes auto.tfvars)
cd phase2-panorama-config
terraform apply -auto-approve

# 4. The new auto.tfvars gets auto-loaded by Phase 1b. Replace FWs:
cd ..
terraform apply -replace='module.firewall.azurerm_linux_virtual_machine.fw["fw1"]' \
                -replace='module.firewall.azurerm_linux_virtual_machine.fw["fw2"]' \
                -target=module.bootstrap -target=module.firewall

# 5. Re-run Phase 2b
bash scripts/register-fw-panorama.sh
```

**Prevention:** avoid manual XML API config-set operations on Panorama
once Phase 2a has succeeded — let terraform manage the entire config
lifecycle. The Phase 2a flow already implements the correct
authkey-generation pattern; ad-hoc CLI/API tinkering with the same
namespace can poison the internal store.

If the workaround fails (i.e., `request authkey add` continues failing
on a fresh Panorama), pin a different PAN-OS version: change
`pan_os_version` in `terraform.tfvars` from `"latest"` to e.g. `"11.2.5"`
and replace Panorama again. 12.1.5 was the only confirmed version where
this manifested — older 11.x and 12.0.x branches have not shown it
in test deployments.
