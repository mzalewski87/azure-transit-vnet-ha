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

## Deployment – 3 Steps

### Step 1: Infrastructure (Phase 1a)

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit: subscription IDs, admin_password, terraform_operator_ips

terraform init
terraform apply \
  -target=azurerm_resource_group.hub \
  -target=azurerm_resource_group.app1 \
  -target=azurerm_resource_group.app2 \
  -target=module.networking \
  -target=module.bootstrap \
  -target=module.panorama \
  -target=module.app2_dc
```

Wait ~15 min for Panorama boot.

### Step 2: Panorama Configuration (Phase 2)

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
cp terraform.tfvars.example terraform.tfvars
# Edit: panorama_password, panorama_serial_number, external_lb_public_ip

terraform init && terraform apply
```

Phase 2 automatically:
1. ⏳ Waits for Panorama API (max 20 min)
2. ✅ Sets hostname via XML API (config mode) + commit
3. ✅ Sets serial number via XML API (config mode) + commit + `request license fetch`
4. ✅ **Generates vm-auth-key automatically** → saved to `../panorama_vm_auth_key.txt`
5. ✅ Creates Template Stack, Device Group, interfaces, zones, routes, NAT, security policies
6. ✅ Final commit

### Step 3: Deploy Firewalls (Phase 1b)

```bash
cd ..  # back to root

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
1. VM creates with `custom_data` (SA pointer) → deallocate → set `userData` → start
2. PAN-OS reads `userData` from IMDS → connects to Azure File Share via `access-key`
3. Downloads `init-cfg.txt` (Panorama IP, Template Stack, Device Group, vm-auth-key)
4. Auto-registers with Panorama using vm-auth-key

### Verification

```bash
# Check FW bootstrap status (via Bastion SSH)
FW1_ID=$(terraform output -raw fw1_vm_id)
az network bastion ssh --name bastion-management --resource-group rg-transit-hub \
  --target-resource-id "$FW1_ID" --auth-type password --username panadmin

admin@fw1> show system bootstrap status
admin@fw1> show panorama-status

# Check connected devices in Panorama
az network bastion ssh --name bastion-management --resource-group rg-transit-hub \
  --target-resource-id "$(terraform output -raw panorama_vm_id)" \
  --auth-type password --username panadmin

admin@panorama> show devices connected
```

---

## Bootstrap – How It Works

FW bootstrap uses **Azure File Share** (not Blob Container) per [PAN-OS documentation](https://docs.paloaltonetworks.com/vm-series/11-1/vm-series-deployment/bootstrap-the-vm-series-firewall/bootstrap-the-vm-series-firewall-in-azure):

```
Storage Account (default_action=Deny, service endpoint + NAT GW IP)
  └── File Share: "bootstrap"
        ├── fw1/
        │   ├── config/init-cfg.txt    ← hostname, panorama-server, tplname, dgname, vm-auth-key
        │   ├── license/authcodes      ← BYOL auth code
        │   ├── content/               ← (empty)
        │   └── software/              ← (empty)
        └── fw2/
            ├── config/init-cfg.txt
            ├── license/authcodes
            ├── content/
            └── software/
```

Bootstrap pointer format (`userData`, base64-encoded):
```
storage-account=sapanosbstrapXXXXXXXX
access-key=<SA primary access key>
file-share=bootstrap
share-directory=fw1
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
| Phase 2 Step 5 | panos provider | Template Stack, Device Group, interfaces, zones, routes, policies |
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

## License

MIT – see [LICENSE](LICENSE)
