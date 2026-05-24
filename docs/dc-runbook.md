# Domain Controller Runbook (`modules/spoke2_dc/` + `optional/dc-promote/`)

Step-by-step deployment, verification, and teardown for the Windows Server
2022 + Active Directory Domain Controller stack on Spoke2. This is an
**optional add-on** to the baseline transit deployment — User-ID integration
with PAN-OS is the only feature that actually consumes it. Skipping this
runbook entirely is supported and does not affect any other test in the
project (the spoke2 VNet exists either way to demonstrate East-West routing).

## What this deploys

Two coordinated layers, applied separately so the slow AD-DS promotion does
not block iteration on the baseline:

| Layer | What it does | Where it lives | Duration |
|---|---|---|---|
| **Part A — DC VM** | `vm-dc-app2` Windows Server 2022 Datacenter in `rg-app2-dc`, NIC on `snet-workload` (10.113.0.0/24) with static IP `10.113.0.4`. No AD role yet. | `module.app2_dc` in root `main.tf` (uses `modules/spoke2_dc/`) | ~5-10 min |
| **Part B — AD promotion** | `Install-WindowsFeature AD-Domain-Services,DNS,RSAT-AD-Tools` + `Install-ADDSForest -DomainName <var.domain_name>` via Custom Script Extension. Auto-reboot when done. | `optional/dc-promote/` (separate workspace) | ~30-45 min |

Domain name default: `panw.labs`. Override via `optional/dc-promote/terraform.tfvars`.

## Architecture

```
                    ┌─────────────────────────────────────┐
                    │  Transit Hub VNet (10.110.0.0/16)   │
                    │  FW1 + FW2 (Active/Active via       │
                    │  External + Internal Standard LB)   │
                    └────────────────┬────────────────────┘
                                     │ peering
                                     │ allow_forwarded_traffic=true
                    ┌────────────────▼────────────────────┐
                    │  Spoke2: App2 VNet (10.113.0.0/16)  │
                    │                                     │
                    │   snet-workload (10.113.0.0/24)     │
                    │      └─ vm-dc-app2                  │
                    │           - Windows Server 2022 DC  │
                    │           - Private IP 10.113.0.4   │
                    │           - Domain: panw.labs       │
                    │           - Roles: AD DS + DNS      │
                    │                                     │
                    │   UDR (rt-spoke2):                  │
                    │      0.0.0.0/0       → 10.110.0.100 │
                    │      10.112.0.0/16   → 10.110.0.100 │
                    │      BGP propagation: OFF           │
                    └────────────────┬────────────────────┘
                                     │ peering
                                     │ (mgmt plane only — Bastion RDP)
                    ┌────────────────▼────────────────────┐
                    │  Management VNet (10.255.0.0/16)    │
                    │                                     │
                    │   Bastion Standard                  │
                    │     → IpConnect / native RDP        │
                    │     → tunnel to 3389                │
                    └─────────────────────────────────────┘

Traffic flows after promotion:
─────────────────────────────────────────────────────────────────────────
DC → Internet:     UDR(0/0 → ILB) → FW(SNAT untrust, App-IDs: ms-update,
                   ntp-base, dns, ssl, web-browsing) → ELB → Internet
DC ↔ App1 (East-West):   UDR(10.112/16 → ILB) → FW(allow east-west) → App1
Bastion → DC:      MGMT VNet peering → snet-workload → 10.113.0.4:3389
```

## Prerequisites

1. **Phase 1a + Phase 1b + Phase 2a + Phase 2b done.** Verify in repo root:
   ```bash
   terraform output -raw panorama_vm_id   # returns a value
   terraform output -raw dc_vm_id 2>/dev/null || true   # may already exist if Phase 1b included DC
   ```
2. **Azure CLI authenticated** to the spoke2 subscription (typically the same as hub):
   ```bash
   az account set --subscription <spoke2-subscription-id>
   ```
3. **Bastion access verified.** No tunnel needed for this runbook (Bastion
   is used post-promotion to RDP into the DC); but confirm Bastion is
   reachable:
   ```bash
   az network bastion show -n bastion-management -g rg-transit-hub --query provisioningState -o tsv
   # expect: Succeeded
   ```

## Deploy — Part A: bare Windows VM

Already part of Phase 1b (`module.app2_dc` is in root `main.tf`). If you ran
the full Phase 1b apply, the VM is already there. To deploy just this VM
without touching anything else:

```bash
cd /path/to/repo   # repo root
terraform apply -target=module.app2_dc
```

Result: `vm-dc-app2` Running, NIC `nic-dc-workload` attached to
`snet-workload`, no AD role installed. RDP works (admin/`dc_admin_password`
from root `terraform.tfvars`) but the VM is a stock Windows server.

Skip this and `terraform destroy -target=module.app2_dc` later if you want
the VM gone entirely.

## Deploy — Part B: promote to Active Directory Domain Controller

The promotion runs in a separate Terraform workspace so it does not block
re-applies of the baseline:

```bash
cd optional/dc-promote/

cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — fill REPLACE_ME values:
#   spoke2_subscription_id = "<same as in root terraform.tfvars>"
#   admin_password         = "<same as dc_admin_password from root>"
# Optional overrides (defaults shown):
#   spoke2_resource_group_name = "rg-app2-dc"
#   dc_vm_name                 = "vm-dc-app2"
#   domain_name                = "panw.labs"

terraform init
terraform apply
```

What happens during apply (~30-45 min total):

| Phase | What's happening |
|---|---|
| 1 | `data.azurerm_virtual_machine.dc` reads the running VM |
| 2 | `azurerm_virtual_machine_extension.promote_dc` (CustomScriptExtension): PowerShell installs `AD-Domain-Services` + `DNS` + RSAT tools |
| 3 | `Install-ADDSForest -DomainName <domain_name> -SafeModeAdministratorPassword <admin_password>` runs |
| 4 | Windows reboots automatically (~5-10 min for AD DS to finalise on first boot) |
| 5 | Extension provisioning state goes `Succeeded` once the VM is back |

Terraform timeouts: `create = 60 min` is set on the extension to absorb
the reboot; `lifecycle.ignore_changes = all` so subsequent `terraform plan`
runs do not re-trigger the extension every time.

## Verification

### Via Bastion → RDP → vm-dc-app2

```bash
# Get DC VM ID
DC_ID=$(az vm show -g rg-app2-dc -n vm-dc-app2 --query id -o tsv)

# Open Bastion RDP tunnel (native client, port 33389 → 3389)
az network bastion rdp \
  --name bastion-management \
  --resource-group rg-transit-hub \
  --target-resource-id "$DC_ID"

# Credentials: dc_admin_username / dc_admin_password (from root terraform.tfvars)
```

Inside the RDP session (PowerShell as administrator):

```powershell
# 1. Secure channel to the domain works
nltest /sc_verify:panw.labs
# Expected: "Trusted DC Connection Status Status = 0 0x0 NERR_Success"
#           "The command completed successfully"

# 2. AD domain info
Get-ADDomain | Select Name,DomainMode,Forest
# Expected: Name=panw, DomainMode=Windows2016Domain (or higher),
#           Forest=panw.labs

# 3. DNS resolves the domain
Resolve-DnsName panw.labs -Type SOA
# Expected: SOA record with primaryServer = vm-dc-app2.panw.labs

# 4. AD DS replication state (single DC, no peers — expect 0 errors)
repadmin /showrepl
```

### Via Panorama (after configuring User-ID Agent — see Notes below)

```
Panorama → Device → User Identification → User Mapping
  → Server Monitoring → expect "vm-dc-app2 (10.113.0.4) Connected"
Monitor → Logs → System
  → filter (description contains 'user-id') → expect periodic user maps
```

## Troubleshooting

### Symptom: extension status `Failed` after ~10 min

Cause: the PowerShell script likely failed on `Install-ADDSForest` —
common causes are admin password complexity (Azure default policy needs
≥12 chars, mixed case, digit, symbol), DNS service not running, or the
VM not being a domain candidate.

Fix:
1. RDP into the VM and inspect the script log:
   ```powershell
   Get-Content C:\WindowsAzure\Logs\Plugins\Microsoft.Compute.CustomScriptExtension\*\CustomScriptHandler.log -Tail 80
   ```
2. If the password rejected: change `dc_admin_password` in root tfvars to a
   compliant one, re-apply Part A, then re-run Part B (`terraform taint
   azurerm_virtual_machine_extension.promote_dc` first to force re-execution).

### Symptom: `nltest /sc_verify:panw.labs` returns `ERROR_NO_LOGON_SERVERS`

Cause: the VM is back from reboot but AD DS service hasn't finished its
first-boot initialisation, or the local DNS client still points at Azure's
default resolver instead of itself.

Fix:
1. Verify `Active Directory Domain Services` service is `Running` in `services.msc`.
2. Verify the NIC's DNS server list shows `10.113.0.4` (itself) — if it still
   shows `168.63.129.16`, the post-promotion DNS auto-config didn't apply.
   Set it manually:
   ```powershell
   Get-NetAdapter | Where-Object Status -eq Up | Set-DnsClientServerAddress -ServerAddresses 10.113.0.4
   ```
3. Wait 2-5 min for AD DS to register itself in DNS, then re-run `nltest`.

### Symptom: AD DS works but East-West to App1 fails

Cause: the FW security policy may not include the App-IDs AD/DNS traffic
generates (`dns`, `kerberos`, `ldap`, `ms-ds-smb`, `msrpc-base`, etc.).

Fix: the policy already includes these — see `modules/panorama_config/main.tf`,
rule `Allow-East-West-Spoke1-to-Spoke2` and `Allow-East-West-Spoke2-to-Spoke1`.
If denied logs appear with these App-IDs, re-push the Device Group:
```bash
bash scripts/register-fw-panorama.sh   # idempotent
```

## Teardown

```bash
# Step 1: remove the promotion extension (cosmetic — AD DS role inside Windows
# is NOT actually uninstalled; the VM still thinks it's a DC)
cd optional/dc-promote/
terraform destroy

# Step 2: destroy the VM itself (this fully removes the DC)
cd /path/to/repo   # repo root
terraform destroy -target=module.app2_dc
```

After destroy, verify:
- `az vm show -g rg-app2-dc -n vm-dc-app2` returns `ResourceNotFound`
- Spoke2 VNet, peerings, UDR remain (still owned by root) — East-West
  routing tests are unaffected
- Panorama Template / Device Group untouched

## Notes

- **User-ID integration is manual.** After promotion, configure the PAN-OS
  User-ID Agent to point at the DC's private IP (`10.113.0.4` by default)
  for user/group-based security policies. Panorama → Device → User
  Identification → User Mapping → Server Monitoring → Add. Authentication
  uses the DC admin credentials from root `terraform.tfvars`. Not automated
  in this module — too tied to the specific User-ID feature set the user wants.

- **`destroy` on `optional/dc-promote/` is shallow.** It only removes the
  CustomScriptExtension Terraform resource record from state — the AD DS
  role inside the running Windows is not uninstalled. To fully clean up,
  destroy the VM itself (Step 2 above).

- **Re-applying Part B does nothing by design.** The
  `azurerm_virtual_machine_extension` has `lifecycle.ignore_changes = all`,
  so once the extension is `Succeeded` Terraform does not re-trigger it.
  To force re-promotion (rare — usually you'd destroy and redeploy):
  `terraform taint azurerm_virtual_machine_extension.promote_dc` then apply.

- **Custom domain name.** Set `domain_name = "your.fqdn"` in
  `optional/dc-promote/terraform.tfvars` before the first apply. Changing
  it after promotion requires a full destroy + redeploy — domain rename
  is not in scope.

- **Why DC was kept in root (not made fully optional).** The Spoke2 VNet,
  peerings, and UDR demonstrate the East-West traffic flow that's
  load-bearing for the demo's network design. Pulling the DC VM out of
  root would leave an empty spoke2 VNet, which is more confusing than
  leaving the VM there as a default (admins can `terraform destroy
  -target=module.app2_dc` to drop the VM while keeping the rest of the
  network topology).
