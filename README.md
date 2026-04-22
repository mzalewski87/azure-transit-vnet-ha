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
           │         ┌──────────▼──────────┐  ┌───────▼───────────────┐
           │         │  Internal LB (Std)  │  │  Management VNet      │
           │         │  10.110.0.100       │  │  (10.255.0.0/16)      │
           │         │  HA Ports (All/0)   │  │                       │
           │         │  HC: TCP 22 (5s/2)  │  │  Panorama 10.255.0.4  │
           │         └──────────┬──────────┘  │  NAT GW (license)     │
           │                    │              │  Bastion Standard    │
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
# Edit: subscription IDs, admin_password, fw_auth_code, terraform_operator_ips

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
2. ✅ Sets hostname via XML API + commit
3. ✅ Sets serial number + commit + `request license fetch`
4. ✅ **Generates vm-auth-key** → saved to `panorama_vm_auth_key.txt`
4b. ✅ **Configures Panorama as Log Collector** (Collector Group via XML API)
5. ✅ Creates Template Stack, Device Group, interfaces, zones, routes, NAT, security policies + **Log Forwarding Profile** (sends traffic/threat/URL logs to Panorama)
6. ✅ Final commit

### Phase 1b: Deploy Firewalls + Load Balancers + Routing

```bash
# Add the auto-generated vm-auth-key to terraform.tfvars:
#   panorama_vm_auth_key = "<key from panorama_vm_auth_key.txt>"

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

### Phase 2b: Register Firewalls on Panorama (automated)

```bash
bash scripts/register-fw-panorama.sh
```

This script automatically:
1. Opens Bastion tunnels to FW1, FW2, and Panorama
2. Reads FW serial numbers (dynamically generated during license activation)
3. Registers FW serials on Panorama (mgt-config + Device Group + Template Stack)
4. Commits on Panorama
5. **Waits for both FWs to connect** (polls `show devices connected`, max 5 min)
6. **Commit & Push to Device Group** — pushes policies + config to both firewalls

> **Without this step, firewalls will NOT appear as managed devices in Panorama.**

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

FW bootstrap uses **direct init-cfg parameters in custom_data/userData** (PAN-OS 10.0+ reads from Azure IMDS):

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

An Azure Storage Account with File Share structure is also provisioned for optional future use
(e.g., uploading `bootstrap.xml`, content packages via Azure Cloud Shell):

```
Storage Account (default_action=Deny, service endpoint + NAT GW IP)
  └── File Share: "bootstrap"
        ├── fw1/config/ license/ content/ software/
        └── fw2/config/ license/ content/ software/
```

Network access: FW management subnet has `Microsoft.Storage` service endpoint + NAT GW public IP in SA `ip_rules` as fallback.

---

## Panorama Activation – How It Works

| Step | Method | Action |
|------|--------|--------|
| Phase 1a | Terraform (azurerm) | Creates Panorama VM – boots with default hostname |
| Phase 2 Step 2 | XML API (config mode) | Sets hostname + commit |
| Phase 2 Step 3 | XML API (config mode) | Sets serial number + commit + `request license fetch` |
| Phase 2 Step 4 | XML API (operational) | Generates vm-auth-key (saved to file) |
| Phase 2 Step 4b | XML API (config mode) | Configures Collector Group for log collection |
| Phase 2 Step 5 | panos provider | Template Stack, Device Group, interfaces, zones, routes, policies, **Log Forwarding Profile** |
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
| `terraform_operator_ips` | Your public IP for SA access |

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
- On failover, the passive FW takes over (stateful session sync via HA2 link)
- **Policies are centrally managed via Panorama** Device Group — changes are pushed to BOTH firewalls simultaneously. No per-FW configuration needed.

To test failover:
```bash
# Deallocate active FW
az vm deallocate --ids $(terraform output -raw fw1_vm_id)

# Traffic should failover to FW2 — test:
curl "http://$(terraform output -raw external_lb_public_ip)/"

# Start FW1 back
az vm start --ids $(terraform output -raw fw1_vm_id)
```

---

## Troubleshooting

### Bootstrap fails (Media Detection Failed)
```bash
# Check userData is set
az vm show -g rg-transit-hub -n vm-panos-fw1 --query "userData" -o tsv | base64 -d

# Check SA network rules
SA=$(terraform output -raw bootstrap_storage_account)
az storage account show --name "$SA" -g rg-transit-hub --query "networkRuleSet" -o json

# Check File Share contents
SA_KEY=$(az storage account keys list --account-name "$SA" -g rg-transit-hub --query "[0].value" -o tsv)
az storage file list --account-name "$SA" --share-name bootstrap --path fw1/config --account-key "$SA_KEY" -o table
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

---

## Project Structure

```
azure_ha_project/
├── main.tf / variables.tf / outputs.tf    Root module
├── modules/
│   ├── bootstrap/          SA + Azure File Share + init-cfg.txt
│   ├── panorama/           Panorama VM (no bootstrap)
│   ├── panorama_config/    panos provider: Template, DG, policies
│   ├── firewall/           VM-Series HA pair + userData workaround
│   ├── networking/         VNets, subnets, NSGs, peerings, Bastion, NAT GW
│   ├── loadbalancer/       External + Internal Standard LB
│   ├── routing/            UDR Route Tables
│   ├── frontdoor/          Azure Front Door Premium
│   ├── spoke1_app/         Ubuntu + Apache
│   └── spoke2_dc/          Windows Server DC
├── phase2-panorama-config/ Separate workspace: Panorama API config
├── scripts/                Helper scripts (check-panorama, generate-vm-auth-key)
└── optional/dc-promote/    Manual DC promotion
```

---

## Author

**Michał Zalewski** ([@mzalewski87](https://github.com/mzalewski87))

## License

MIT – see [LICENSE](LICENSE)
