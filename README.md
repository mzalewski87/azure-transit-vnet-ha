# Azure Transit VNet – Palo Alto VM-Series HA

Terraform IaC for **Palo Alto Networks Azure Transit VNet** reference architecture with VM-Series Active/Passive HA pair managed by Panorama.

> **Ref:** [PANW Azure Transit VNet Deployment Guide](https://www.paloaltonetworks.com/apps/pan/public/downloadResource?pagePath=/content/pan/en_US/resources/guides/azure-transit-vnet-deployment-guide)

---

## Architecture

```
                            ┌───────────────┐
                            │   INTERNET    │
                            └──────┬────────┘
                                   │
                    ┌──────────────▼──────────────┐
                    │  Azure Front Door Premium   │
                    │  (WAF, global L7 LB, TLS)   │
                    └──────────────┬──────────────┘
                                   │ HTTPS
                    ┌──────────────▼──────────────┐
                    │  External LB (Standard)     │
                    │  pip-external-lb            │
                    │  Rules: TCP 80, TCP 443     │
                    │  Health: TCP 22 (5s/2probe) │
                    │  SNAT outbound rule         │
                    └──────────────┬──────────────┘
                                   │
  ┌────────────────────────────────▼─────────────────────────────────────┐
  │  Transit Hub VNet (10.110.0.0/16)                                    │
  │                                                                      │
  │   snet-public (10.110.129.0/24) ─── FW eth1/1 (untrust, DHCP)        │
  │        ┌──────────┐  ┌──────────┐                                    │
  │        │  FW1 (A) │  │  FW2 (P) │  VM-Series Active/Passive HA       │
  │        └────┬─────┘  └────┬─────┘                                    │
  │   snet-private (10.110.0.0/24) ─── FW eth1/2 (trust, DHCP)           │
  │   snet-ha (10.110.128.0/24)    ─── FW eth1/3 (HA2 data sync)         │
  │   snet-mgmt (10.110.255.0/24)  ─── FW eth0 (mgmt, HA1)               │
  │        │  NAT GW (license/updates)                                   │
  └────────┼─────────────────────────────────────────────────────────────┘
           │                    │ peering              │ peering
           │         ┌──────────▼──────────┐   ┌──────▼───────────────┐
           │         │  Internal LB (Std)  │   │  Management VNet     │
           │         │  10.110.0.100       │   │  (10.255.0.0/16)     │
           │         │  HA Ports (All/0)   │   │                      │
           │         │  HC: TCP 22 (5s/2)  │   │  Panorama 10.255.0.4 │
           │         └──────────┬──────────┘   │  NAT GW (license)    │
           │                    │              │   Bastion Standard   │
           │         next-hop=VirtualAppliance │  (tunnel + IpConnect)│
           │                    │              └───┬────────┬─────────┘
  ┌────────▼────────────────────▼───┐              │peer    │peer
  │                                 │              │        │
  │   ┌─────────────────────────┐   │   ┌─────────▼────────▼──────────┐
  │   │  Spoke1: App1 VNet      │   │   │  Spoke2: App2 VNet          │
  │   │  (10.112.0.0/16)        │◄──┼──►│  (10.113.0.0/16)            │
  │   │                         │   │   │                             │
  │   │  Ubuntu + Apache        │   │   │  Windows Server DC          │
  │   │  10.112.0.4             │   │   │  10.113.0.4                 │
  │   │                         │   │   │                             │
  │   │  UDR (rt-spoke1):       │   │   │  UDR (rt-spoke2):           │
  │   │   0.0.0.0/0 → ILB       │   │   │   0.0.0.0/0 → ILB           │
  │   │   10.113.0.0/16 → ILB   │   │   │   10.112.0.0/16 → ILB       │
  │   │   BGP propagation: OFF  │   │   │   BGP propagation: OFF      │
  │   └─────────────────────────┘   │   └─────────────────────────────┘
  └─────────────────────────────────┘

  VNet Peerings (bidirectional, allow_forwarded_traffic=true):
  ─────────────────────────────────────────────────────────────
  Management ↔ Transit Hub    (Panorama ↔ FW mgmt plane)
  Management ↔ App1           (Bastion → App1 VMs)
  Management ↔ App2           (Bastion → App2/DC VMs)
  Transit Hub ↔ App1          (data plane: UDR traffic)
  Transit Hub ↔ App2          (data plane: UDR traffic)

  Traffic Flows:
  ─────────────────────────────────────────────────────────────
  Inbound:    AFD → ELB → FW(DNAT) → ILB → App1 Apache
  Outbound:   App → UDR(0/0→ILB) → FW(SNAT) → ELB → Internet
  East-West:  App1 → UDR(→ILB) → FW(inspect) → ILB → App2
```

---

## Prerequisites

```bash
terraform >= 1.5.0
azure-cli >= 2.50.0
python3 >= 3.8
```

- Azure subscription(s) with `Contributor` + `User Access Administrator`
- **Panorama BYOL**: auth-code → registered on [CSP Portal](https://my.paloaltonetworks.com) → Serial Number
- **VM-Series BYOL**: auth-code(s) from CSP Portal

---

## Deployment – 5 Phases

### Phase 1a: Infrastructure (Panorama + Networking)

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit: subscription IDs, admin_password, fw_auth_code

terraform init
terraform apply \
  -target=azurerm_resource_group.hub \
  -target=azurerm_resource_group.app1 \
  -target=azurerm_resource_group.app2 \
  -target=module.networking \
  -target=module.bootstrap \
  -target=module.panorama
```

Wait ~15 min for Panorama to boot.

### Phase 2a: Panorama Configuration (automated)

**Recommended** — single script handles Bastion tunnel + Terraform automatically:
```bash
cd phase2-panorama-config/
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — set these REQUIRED values:
#   panorama_password      = "<same as admin_password from Phase 1>"
#   panorama_serial_number = "<from CSP Portal, e.g. 007300XXXXXXX>"
#
# external_lb_public_ip is AUTO-POPULATED by the script from terraform output.
# If needed manually: terraform output -raw external_lb_public_ip

cd ..  # back to root
bash scripts/configure-panorama.sh
```

<details>
<summary>Manual alternative (if script fails)</summary>

**Terminal 1** – Bastion tunnel (keep open):
```bash
PANORAMA_ID=$(terraform output -raw panorama_vm_id)
az network bastion tunnel \
  --name bastion-management --resource-group rg-transit-hub \
  --target-resource-id "$PANORAMA_ID" \
  --resource-port 443 --port 44300
```

**Terminal 2** – Phase 2 apply:
```bash
cd phase2-panorama-config/
terraform init && terraform apply
```
</details>

Phase 2a automatically:
1. ⏳ Waits for Panorama API (max 20 min)
2. ✅ Sets hostname via XML API + commit (also: timezone Europe/Warsaw, NTP, EU telemetry)
3. ✅ Sets serial number + commit + `request license fetch`
4. ✅ **Generates vm-auth-key** → saved to `panorama_vm_auth_key.txt` and auto-injected
   into root via `panorama_vm_auth_key.auto.tfvars`
4b. ✅ **Configures Panorama as Log Collector** (Collector Group via XML API)
5. ✅ Creates **Template + Template Stack + Device Group** with the full data-plane
   config: ethernet interfaces (DHCP), security zones, **multi-VR architecture**
   (VR-External + VR-Internal for Azure LB sandwich), static routes, **Log Forwarding
   Profile**, App-ID-aware security rules, NAT rules (DNAT inbound + SNAT outbound).
5b. ✅ **Pushes HA configuration to Template** (group-id=1, active-passive, HA1 on
   management interface, HA2 on ethernet1/3) plus declares Template Variables
   `$ha-peer-ip` and `$ha-priority` with placeholders. Per-device overrides happen
   in Phase 2b after FW serials are known.
5c. ✅ **Creates Zone Protection Profiles**: `Azure-Internet-Protection` (untrust:
   SYN/UDP/ICMP flood + TCP/UDP port-scan + host-sweep + packet-based defenses)
   and `Azure-Internal-Protection` (trust: packet-based defenses only). Attached
   to zones via XML API.
5d. ✅ **Administrative-access hardening** on FW Template: password complexity (12+
   chars + upper/lower/digit/special, 90-day rotation, 10-password history),
   15-minute idle timeout, login banner. Note: GUI sessions will idle out — this
   is intentional, not a bug.
6. ✅ Final commit

### Phase 1b: Deploy Firewalls + Load Balancers + Routing

```bash
# vm-auth-key was auto-injected into terraform.tfvars by Phase 2a script

terraform apply -target=module.bootstrap    # update init-cfg with vm-auth-key
terraform apply \
  -target=module.loadbalancer \
  -target=module.firewall \
  -target=module.routing \
  -target=module.frontdoor \
  -target=module.app1_app
```

FW bootstrap process:
1. VM created with `custom_data` containing init-cfg parameters (base64-encoded)
2. Deallocate → set `userData` via az CLI → start (workaround for azurerm marketplace VM bug)
3. PAN-OS reads init-cfg from Azure IMDS on first boot (direct parameters, no File Share needed)
4. Activates license using `authcodes` from init-cfg
5. Connects to Panorama using `panorama-server`, `tplname`, `dgname`, `vm-auth-key`

> **Note:** FW registration on Panorama is NOT complete after this phase.
> Phase 2b is required to register FW serial numbers on Panorama.
>
> **Wait ~10–15 min** for FW bootstrap to complete (PAN-OS boot + license activation)
> before running Phase 2b. The script will wait automatically, but starting too early
> adds unnecessary delay.

### Phase 2b: Register Firewalls on Panorama (automated)

```bash
bash scripts/register-fw-panorama.sh
```

This script automatically:
1. Opens Bastion tunnels to FW1, FW2, and Panorama
2. Reads FW serial numbers (dynamically generated during license activation) and
   their management IPs from `terraform output`
3. Registers FW serials on Panorama (mgt-config + Device Group + Template Stack)
4. **Sets per-device HA Template Variable overrides** — FW1 (active) gets
   `$ha-peer-ip = <FW2 mgmt IP>/24` + `$ha-priority = 100`; FW2 (passive) gets
   `$ha-peer-ip = <FW1 mgmt IP>/24` + `$ha-priority = 200`. This is what makes HA
   actually form — without it the placeholder peer-ip from Phase 2a Step 5b means
   HA never establishes.
5. Commits on Panorama
6. **Waits for both FWs to connect** (polls `show devices connected`, max 5 min)
7. **Push Template Stack to devices** (interfaces, zones, VR, routes, HA config)
8. **Push Device Group to devices** (security policies, NAT rules)
9. Push Collector Group (Device Log Forwarding mapping)

> **Without this step, firewalls will NOT appear as managed devices in Panorama
> AND HA will not form** (peer-ip stays as the placeholder default from Step 5b).

### Phase 3: Domain Controller (optional)

```bash
terraform apply -target=module.app2_dc
```

See `optional/dc-promote/` for Active Directory promotion.

### Verification

```bash
# Check FW bootstrap status (via Bastion SSH)
FW1_ID=$(terraform output -raw fw1_vm_id)
az network bastion ssh --name bastion-management --resource-group rg-transit-hub \
  --target-resource-id "$FW1_ID" --auth-type password --username panadmin

admin@fw1> show system bootstrap status
admin@fw1> show system info | match serial
admin@fw1> show panorama-status          # should show Connected: yes

# Check connected devices in Panorama
az network bastion ssh --name bastion-management --resource-group rg-transit-hub \
  --target-resource-id "$(terraform output -raw panorama_vm_id)" \
  --auth-type password --username panadmin

admin@panorama> show devices connected    # should list fw1 + fw2
```

---

## Bootstrap – How It Works

FW bootstrap uses **direct init-cfg parameters in custom_data/userData** (PAN-OS 10.0+
reads from Azure IMDS — no SMB share required):

```
custom_data (base64-encoded init-cfg):
  type=dhcp-client
  hostname=fw1-transit-hub
  panorama-server=10.255.0.4
  tplname=Transit-VNet-Stack
  dgname=Transit-VNet-DG
  vm-auth-key=2:XXXXXX...
  authcodes=XXXX-XXXX-XXXX-XXXX
  dns-primary=168.63.129.16
```

The rendered files are also written to `modules/bootstrap/rendered/fw{1,2}-init-cfg.txt`
for inspection during troubleshooting (gitignored).

A User Assigned Managed Identity is created and attached to both FW VMs so PAN-OS can
authenticate to other Azure services (Key Vault, Storage, Monitor) when needed in the
future. It carries no role assignments today.

> **Why no Azure File Share scaffold?** The classic PAN-OS bootstrap on Azure expects
> SMB files under `bootstrap/fw{1,2}/config/init-cfg.txt` + `bootstrap/fw{1,2}/license/authcodes`.
> In environments where corporate SSL inspection blocks PUT requests to
> `*.file.core.windows.net` (Terraform Go client and curl both return "connection reset"),
> file uploads can never complete. The IMDS path bypasses the data plane entirely and
> is officially supported by PAN-OS 10.0+.

---

## Panorama Activation – How It Works

| Step | Method | Action |
|------|--------|--------|
| Phase 1a | Terraform (azurerm) | Creates Panorama VM – boots with default hostname |
| Phase 2 Step 2 | XML API (config mode) | Sets hostname + timezone + NTP + EU telemetry + commit |
| Phase 2 Step 3 | XML API (operational) | Sets serial number + commit + `request license fetch` |
| Phase 2 Step 4 | XML API (operational) | Generates vm-auth-key (saved to file + auto.tfvars) |
| Phase 2 Step 4b | XML API (config mode) | Configures Panorama as Managed Collector + Collector Group |
| Phase 2 Step 5 | panos provider | Template + Template Stack + Device Group + interfaces + zones + multi-VR + routes + NAT + App-ID-aware security rules + Log Forwarding Profile |
| Phase 2 Step 5b | XML API (config mode) | **HA configuration in Template** + Template Variables `$ha-peer-ip`, `$ha-priority` |
| Phase 2 Step 5c | XML API (config mode) | **Zone Protection Profiles** (`Azure-Internet-Protection` on untrust, `Azure-Internal-Protection` on trust) |
| Phase 2 Step 5d | XML API (config mode) | **Admin hardening**: password complexity, idle timeout, login banner |
| Phase 2 Step 6 | XML API | Final commit |
| Phase 2b Step 4 | XML API (config mode) | **Per-device HA variable overrides** — FW1 priority 100 + peer FW2; FW2 priority 200 + peer FW1 |

**Serial number activation** uses config mode (not operational `request serial-number set`), which is more reliable across PAN-OS versions:
```
type=config, action=set
xpath=/config/devices/entry[@name='localhost.localdomain']/deviceconfig/system
element=<serial-number>007300XXXXXXX</serial-number>
```

**vm-auth-key** is generated automatically in Phase 2 Step 4. No manual SSH required.

---

## Key Variables

### Phase 1 – root terraform.tfvars

| Variable | Description |
|----------|-------------|
| `hub_subscription_id` | Hub subscription (Management + Transit VNet) |
| `admin_password` | Password for Panorama and FW (min 12 chars) |
| `panorama_vm_auth_key` | Auto-generated in Phase 2 Step 4 |
| `fw_auth_code` | VM-Series BYOL auth code from CSP Portal |

### Phase 2 – phase2-panorama-config/terraform.tfvars

| Variable | Description |
|----------|-------------|
| `panorama_password` | Same as `admin_password` in Phase 1 |
| `panorama_serial_number` | From CSP Portal (format: `007300XXXXXXX`) |
| `external_lb_public_ip` | `terraform output external_lb_public_ip` |

---

## Bastion Access

```bash
# SSH to Panorama
az network bastion ssh --name bastion-management --resource-group rg-transit-hub \
  --target-resource-id "$(terraform output -raw panorama_vm_id)" \
  --auth-type password --username panadmin

# SSH to FW1
az network bastion ssh --name bastion-management --resource-group rg-transit-hub \
  --target-resource-id "$(terraform output -raw fw1_vm_id)" \
  --auth-type password --username panadmin

# HTTPS tunnel to Panorama GUI
az network bastion tunnel --name bastion-management --resource-group rg-transit-hub \
  --target-resource-id "$(terraform output -raw panorama_vm_id)" \
  --resource-port 443 --port 44300
# Then: open https://localhost:44300

# Helper script
./scripts/check-panorama.sh           # status + commands
./scripts/check-panorama.sh --tunnel  # HTTPS tunnel
./scripts/check-panorama.sh --rdp     # RDP to DC
```

---

## Testing Traffic Flows

### Inbound: Azure Front Door → FW → Apache

```bash
# Get Front Door endpoint URL
AFD_HOST=$(terraform output -raw frontdoor_endpoint)
echo "Front Door URL: https://$AFD_HOST"

# Test via Front Door (global L7 LB → ELB → FW DNAT → Apache)
curl -v "https://$AFD_HOST/"

# Direct test via External LB (bypass AFD)
ELB_IP=$(terraform output -raw external_lb_public_ip)
curl -v "http://$ELB_IP/"
```

Expected: Apache "Hello World" page from Spoke1 VM (10.112.0.4).

### Outbound: DC → Internet (via FW)

```bash
# SSH to DC via Bastion (RDP tunnel for GUI)
DC_ID=$(terraform output -raw dc_vm_id)
az network bastion tunnel --name bastion-management --resource-group rg-transit-hub \
  --target-resource-id "$DC_ID" --resource-port 3389 --port 33389
# Then: RDP to localhost:33389, open browser → internet traffic goes through FW
```

DC outbound traffic flow: `DC (10.113.0.4) → UDR 0/0 → ILB → FW (SNAT) → ELB → Internet`

### East-West: DC ↔ Ubuntu (via FW)

```bash
# From DC (via RDP/PowerShell):
Test-NetConnection -ComputerName 10.112.0.4 -Port 80

# From Ubuntu (via Bastion SSH):
curl http://10.113.0.4
```

East-west flow: `DC → UDR → ILB → FW (inspect) → ILB → Ubuntu` (and reverse)

### Verify Logs in Panorama

After running traffic tests, check logs on Panorama:
```
admin@panorama> show log traffic direction equal forward
```

Or via Panorama GUI: **Monitor → Traffic** — filter by source/destination.

> **Note:** Logs require Phase 2b completed (FW registered on Panorama) and Log Forwarding Profile
> configured (done automatically in Phase 2a Step 4b + Step 5).

---

## HA Mode – Active/Passive with Azure LB

This architecture uses **Active/Passive HA** with Azure Standard Load Balancer:

- **Azure LB** (HA Ports mode) distributes traffic to both FWs
- **PAN-OS HA** is Active/Passive — one FW handles sessions, the other is standby
- HA1 (control plane) heartbeat over the management interface (eth0)
- HA2 (state sync) over the dedicated `snet-ha` subnet (ethernet1/3)
- On failover, the passive FW takes over (stateful session sync via HA2 link)
- **Policies are centrally managed via Panorama** Device Group — changes are pushed to BOTH firewalls simultaneously. No per-FW configuration needed.

### HA Configuration — How It's Wired

The HA template lives in the FW Template, but `peer-ip` and `device-priority`
differ per FW. They are exposed as Template Variables (`$ha-peer-ip`,
`$ha-priority`) with placeholder defaults — actual values are set per FW serial
in **Phase 2b Step 4** (`scripts/register-fw-panorama.sh`):

| FW | Role | Device Priority | `$ha-peer-ip` |
|----|------|-----------------|---------------|
| FW1 | active | 100 (lower wins election) | FW2 management IP / 24 |
| FW2 | passive | 200 | FW1 management IP / 24 |

Preemption is **off** — once FW2 takes over, it stays active until a manual
fail-back. This avoids flapping during maintenance.

### Verify HA after deployment

```bash
# SSH to FW1 via Bastion, then on the PAN-OS CLI:
admin@fw1> show high-availability state
# Expected: "State: active", "Peer state: passive"

admin@fw1> show high-availability state-synchronization
# HA2 link should show "Connection: up", "ha2-keep-alive: enabled"

# Same on FW2 — should be the mirror image:
admin@fw2> show high-availability state
# Expected: "State: passive", "Peer state: active"
```

### Test failover

```bash
# Deallocate active FW
az vm deallocate --ids $(terraform output -raw fw1_vm_id)

# Traffic should failover to FW2 — test:
curl "http://$(terraform output -raw external_lb_public_ip)/"

# Verify FW2 is now active (via Bastion SSH):
admin@fw2> show high-availability state    # should now show "State: active"

# Start FW1 back — it will rejoin as passive (preemption is OFF)
az vm start --ids $(terraform output -raw fw1_vm_id)
```

---

## Troubleshooting

### Bootstrap fails (Media Detection Failed)
```bash
# Verify userData is actually set on the VM (this is what PAN-OS reads via IMDS)
az vm show -g rg-transit-hub -n vm-panos-fw1 --query "userData" -o tsv | base64 -d

# Compare to the rendered init-cfg on disk (what Terraform generated)
cat modules/bootstrap/rendered/fw1-init-cfg.txt

# Check userData propagation: customData was set on VM creation, then the
# null_resource in modules/firewall/main.tf re-applies it via 'az vm update --user-data'
# (workaround for azurerm marketplace VMs not propagating user_data through plan{} block).
# If userData is empty after deploy, that null_resource provisioner failed — re-run:
terraform apply -target=module.firewall

# Inspect bootstrap log on the FW (via Bastion SSH)
admin@fw1> less mp-log bootstrap.log
admin@fw1> show system bootstrap status
```

### Panorama license fetch fails
```bash
# Check serial number
admin@panorama> show system info | match serial

# Check internet access (NAT Gateway)
admin@panorama> ping host 8.8.8.8 source 10.255.0.4

# Manual fix
admin@panorama> configure
admin@panorama# set deviceconfig system serial-number 007300XXXXXXX
admin@panorama# commit
admin@panorama# exit
admin@panorama> request license fetch
```

### FW not registering with Panorama
```bash
admin@fw1> show panorama-status
admin@fw1> show system bootstrap status
admin@fw1> less mp-log bootstrap.log
```

### HA does not form (both FWs show as active, or both as passive)

Almost always caused by Phase 2b skipping the per-device variable override.
Symptoms: `show high-availability state` on each FW shows the placeholder
peer-ip (10.0.0.254 by default) or both FWs report "active".

```bash
# Re-run Phase 2b — it is idempotent:
bash scripts/register-fw-panorama.sh

# Verify the per-device variables landed in Panorama:
#   Panorama GUI -> Panorama -> Managed Devices -> <serial> -> "Variables" tab
# Should show: $ha-peer-ip = <other FW mgmt IP>/24, $ha-priority = 100 or 200

# After fixing, push the Template Stack so each FW pulls the new variable:
#   Panorama GUI -> Commit -> Push to Devices -> Template Stack
```

### Traffic blocked unexpectedly by Deny-All

The `Allow-East-West-*` and `Allow-Outbound-Internet` rules use **explicit
App-IDs** (web-browsing, ssl, ssh, dns, kerberos, ldap, ms-ds-smb, ms-rdp,
ntp-base, ms-update, ...). Anything not on the list hits the Deny-All catch-all
and is logged.

```bash
# Find what was denied:
#   Panorama GUI -> Monitor -> Traffic
#   filter: ( rule eq 'Deny-All' ) and ( src in <YOUR_SOURCE> )
# The "Application" column tells you which App-ID PAN-OS resolved.
# Add it to the relevant rule's applications list in
#   modules/panorama_config/main.tf -> panos_panorama_security_rule_group.transit
# then re-apply Phase 2 + push Device Group.
```

### GUI session keeps logging me out

By design — `null_resource.fw_template_admin_hardening` sets a 15-minute idle
timeout per the PANW Administrative Access Best Practices. To change the value
edit the `idle-timeout` element in `modules/panorama_config/main.tf` and re-push
the Template Stack.

### Admin password rotation prompt every 90 days

Same source — password complexity policy enforces 90-day rotation with a
7-day warning and a 3-day post-expiration grace period. Adjust the
`expiration-period` element in the same null_resource if you need a different
cadence.

---

## Project Structure

```
azure_ha_project/
├── main.tf / variables.tf / outputs.tf    Root module
├── modules/
│   ├── bootstrap/          init-cfg renderer (base64 -> custom_data via IMDS) + UAMI
│   ├── panorama/           Panorama VM (no bootstrap)
│   ├── panorama_config/    panos provider + XML API: Template, DG, HA, Zone Protection, App-ID rules
│   ├── firewall/           VM-Series HA pair (for_each over fw_names) + userData workaround
│   ├── networking/         VNets, subnets, NSGs, peerings, Bastion, NAT GW
│   ├── loadbalancer/       External + Internal Standard LB (HA Ports rule)
│   ├── routing/            UDR Route Tables for spokes
│   ├── frontdoor/          Azure Front Door Premium
│   ├── spoke1_app/         Ubuntu + Apache
│   └── spoke2_dc/          Windows Server DC
├── phase2-panorama-config/ Separate workspace: Panorama API config (panos + XML API)
├── scripts/                Helper scripts (check-panorama, register-fw-panorama, ...)
├── optional/dc-promote/    Manual DC promotion
└── docs/
    ├── ROADMAP-swfw-modules-migration.md   Future v2 plan (partial swfw-modules adoption)
    └── reference/
        ├── links.md        Curated PANW + Azure + Terraform URLs
        └── pdfs/           Vendor PDFs (gitignored, see INDEX.md catalogue)
```

---

## Author

**Michał Zalewski** ([@mzalewski87](https://github.com/mzalewski87))

## License

MIT – see [LICENSE](LICENSE)
