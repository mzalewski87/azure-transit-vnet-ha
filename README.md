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
  │        │   FW1    │  │   FW2    │  VM-Series farm behind Azure LB    │
  │        └────┬─────┘  └────┬─────┘  (no PAN-OS HA pair — see below)   │
  │   snet-private (10.110.0.0/24) ─── FW eth1/2 (trust, DHCP)           │
  │   snet-mgmt (10.110.255.0/24)  ─── FW eth0  (management)             │
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
2. Reads FW serial numbers (dynamically generated during license activation)
3. Registers FW serials on Panorama (mgt-config + Device Group + Template Stack)
4. Adds FWs to the Collector Group's Device Log Forwarding preference list
5. Commits on Panorama
6. **Waits for both FWs to connect** (polls `show devices connected`, max 5 min)
7. **Push Template Stack to devices** — interfaces, zones, virtual routers, routes
8. **Push Device Group to devices** — security policies, NAT rules
9. Push Collector Group (so logs from both FWs land on the Panorama log collector)

> **Without this step, firewalls will NOT appear as managed devices in Panorama**
> and the Template Stack / Device Group / Collector Group won't be pushed,
> so the FWs sit there licensed but unconfigured.

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
| Phase 2 Step 5c | XML API (config mode) | **Zone Protection Profiles** (`Azure-Internet-Protection` on untrust, `Azure-Internal-Protection` on trust) |
| Phase 2 Step 5d | XML API (config mode) | **Admin hardening**: password complexity, idle timeout, login banner |
| Phase 2 Step 6 | XML API | Final commit |

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

## Azure-Native HA + Configuration Management via Panorama

This deployment follows the **PANW Securing Applications in Azure deployment
guide** (DEC 2024) verbatim: VM-Series firewalls in Azure run **without** a
classic PAN-OS Active/Passive HA pair. Instead, two complementary mechanisms
provide resilience and consistency:

| Concern | Azure handles | Panorama handles |
|---|---|---|
| **Failover when a FW dies** | Standard LB health probes + HA Ports rule | — |
| **Same config on both FWs** | — | Device Group + Template Stack push |
| **Centralised policy / NAT / zones** | — | Device Group |
| **Centralised network config (interfaces, VRs, routes)** | — | Template Stack |
| **Centralised log forwarding** | — | Collector Group |

### Failover via Azure Standard LB health probes (no PAN-OS HA pair)

Both FW1 and FW2 are simultaneously active in the load-balancer backend pool —
each FW handles sessions independently and Azure LB load-balances new sessions
across them. There is no HA1 heartbeat, no HA2 state sync, no peer-ip, no
device-priority. Failover is handled at the LB layer:

- **Internal LB** (HA Ports rule on protocol=All / port=0) probes each FW on
  HTTPS `/php/login.php` every 5 seconds. After 2 failed probes the FW is
  drained from the backend pool — outbound + east-west sessions reroute to
  the surviving FW within ~10 seconds.
- **External LB** does the same on the inbound path with floating IP enabled
  (so PAN-OS DNAT rules match the public IP correctly).
- An Availability Set across two fault domains ensures FW1 and FW2 are never
  on the same physical hardware, so a single host failure cannot take both
  out simultaneously.

> **Trade-off:** there is no session-state synchronisation between FW1 and FW2.
> When a FW goes down, in-flight TCP/TLS sessions on it are lost — the client
> must re-establish them, and the new sessions land on the surviving FW. For
> stateless or short-lived flows (HTTP, DNS, NTP, application API calls)
> this is invisible. For long-lived sessions (SSH, RDP, persistent VPN) the
> user sees a brief reconnect. PANW Azure deployment guide accepts this
> trade-off in exchange for not fighting Azure's L3-only fabric (raw L2 HA2
> sync via Ethertype 0x7261 doesn't work in Azure).

### Configuration consistency via Panorama (Device Group + Template Stack)

Both firewalls are members of the same Panorama **Device Group**
(`Transit-VNet-DG`) and the same **Template Stack** (`Transit-VNet-Stack`).
This is what guarantees they always run identical config:

| Panorama object | What it pushes | Why both FWs always match |
|---|---|---|
| **Template Stack** (`Transit-VNet-Stack`) | Network config — ethernet interfaces (eth1/1 untrust, eth1/2 trust), security zones (untrust, trust), virtual routers (multi-VR for Azure LB sandwich), static routes, interface management profile (HTTPS for LB health probes), system settings (timezone, NTP, telemetry), administrative-access hardening (password policy, idle timeout), log settings | A `commit-all template-stack` job (Phase 2b Step 8/9 of `register-fw-panorama.sh`) sends the SAME compiled template to every FW listed under the Stack's `devices` block |
| **Device Group** (`Transit-VNet-DG`) | Security policy rules (Allow-Inbound-Web, Allow-East-West-*, Allow-Outbound-Internet with App-ID, Allow-Azure-LB-Probes, Deny-All), NAT rules (DNAT inbound, SNAT outbound), Log Forwarding Profile, Zone Protection Profile attachments | A `commit-all shared-policy device-group` job (Phase 2b Step 9/9) pushes the SAME policy + NAT set to every FW in the DG |
| **Collector Group** (`default`) | Log Forwarding routing — every FW sends traffic/threat/url logs to the same Panorama log collector | Pushed in Phase 2b Step 9.5/9 |

If you change anything in `modules/panorama_config/main.tf`, the workflow is:

```bash
# 1. Apply the change to Panorama candidate config
cd phase2-panorama-config
terraform apply
# 2. Push the new template/DG to all FWs (idempotent — pushes whatever's currently in Panorama)
cd ..
bash scripts/register-fw-panorama.sh
```

You can also push manually from the Panorama GUI: **Commit → Commit and Push**,
selecting the Template Stack and Device Group.

### Verify both firewalls are in sync (Panorama-side)

```bash
PANORAMA_ID=$(terraform output -raw panorama_vm_id)
az network bastion ssh --name bastion-management --resource-group rg-transit-hub \
  --target-resource-id "$PANORAMA_ID" --auth-type password --username panadmin

admin@panorama> show devices connected
# Expect both FW serials listed, "Connected: yes"

admin@panorama> show devices all
# Look at the "Shared Policy" and "Template" columns — both should say "In sync"
# If "Out of sync" — push the corresponding object: Commit → Commit and Push → ...
```

### Verify the Azure LB sees both FWs as healthy

```bash
# Internal LB health probe status (Azure side):
az network lb show -g rg-transit-hub -n lb-internal-transit \
  --query 'backendAddressPools[0].loadBalancerBackendAddresses[].{nic:networkInterfaceIPConfiguration.id,ip:ipAddress}' -o table

# Live probe results — show the running state of backend instances:
az network lb show -g rg-transit-hub -n lb-internal-transit --query 'probes' -o json
```

In the Azure Portal: **Load Balancers → lb-internal-transit → Insights → Backend health** —
both FWs should show as "Up".

### Test failover (drain one FW, traffic continues via the other)

```bash
# Take FW1 out of service:
FW1_ID=$(terraform output -raw fw1_vm_id)
az vm deallocate --ids "$FW1_ID"

# Within ~10s the Internal LB health probe (HA Ports, HTTPS /php/login.php,
# 5s interval x 2 probes) marks FW1 unhealthy and drains it from the pool.
# Outbound + east-west traffic continues via FW2:
ELB_IP=$(terraform output -raw external_lb_public_ip)
curl -v "http://$ELB_IP/"   # should still return Apache page

# Bring FW1 back:
az vm start --ids "$FW1_ID"
# After PAN-OS finishes booting (~5-10 min) and responds to /php/login.php
# probes, LB adds it back to the pool. New sessions distribute across both
# FWs again.
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

### `show high-availability state` returns "HA not enabled"

That's intentional — this deployment does NOT configure PAN-OS HA Active/Passive
between the firewalls. Failover is provided by Azure Standard LB health probes
instead. See "Azure-Native HA + Configuration Management via Panorama" above
for the full rationale (matches PANW Securing Applications in Azure deployment
guide). To verify failover works at the LB layer, drain a FW with
`az vm deallocate` and confirm traffic continues via the surviving FW.

### Both FWs marked "Out of sync" in Panorama → Managed Devices

Re-run the relevant push:

```bash
# Re-run all of Phase 2b (idempotent):
bash scripts/register-fw-panorama.sh

# Or push manually from Panorama GUI:
#   Commit → Commit and Push → select Template Stack and Device Group → Push
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
│   ├── panorama_config/    panos provider + XML API: Template, DG, Zone Protection, App-ID rules
│   ├── firewall/           VM-Series farm (for_each over fw_names) + userData workaround
│   ├── networking/         VNets, subnets (3 transit subnets — no snet-ha), NSGs, peerings, Bastion, NAT GW
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
