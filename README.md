# Azure Transit VNet – Palo Alto VM-Series HA

Terraform IaC for **Palo Alto Networks Azure Transit VNet** reference architecture with VM-Series Active/Passive HA pair managed by Panorama.

> **Ref:** [PANW Azure Transit VNet Deployment Guide](https://www.paloaltonetworks.com/apps/pan/public/downloadResource?pagePath=/content/pan/en_US/resources/guides/azure-transit-vnet-deployment-guide)

---

## Architecture

```
  ┌─────────────────────────────────────────────────────────────────────────┐
  │  Management VNet (10.255.0.0/16)                                       │
  │    snet-management: Panorama (10.255.0.4) + NAT Gateway               │
  │    AzureBastionSubnet: Bastion Standard (cross-VNet SSH/tunnel)        │
  ├─────────────────────────────────────────────────────────────────────────┤
  │  Transit Hub VNet (10.110.0.0/16)                                      │
  │    snet-mgmt (10.110.255.0/24)    FW eth0 – management, HA1           │
  │    snet-public (10.110.129.0/24)  FW eth1/1 – untrust, External LB    │
  │    snet-private (10.110.0.0/24)   FW eth1/2 – trust, Internal LB     │
  │    snet-ha (10.110.128.0/24)      FW eth1/3 – HA2 data sync          │
  ├─────────────────────────────────────────────────────────────────────────┤
  │  App1 VNet (10.112.0.0/16)  Ubuntu+Apache │ App2 VNet (10.113.0.0/16) │
  │  UDR → 10.110.0.21 (ILB)                  │ Windows DC, UDR → ILB     │
  ├─────────────────────────────────────────────────────────────────────────┤
  │  Azure Front Door Premium → External LB → FW → ILB → App1            │
  └─────────────────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

```bash
terraform >= 1.5.0
azure-cli >= 2.50.0
python3 >= 3.8
curl
```

- Azure subscription(s) with `Contributor` + `User Access Administrator`
- **Panorama BYOL**: serial number from [CSP Portal](https://my.paloaltonetworks.com) (deployment profile)
- **VM-Series BYOL**: auth code from CSP Portal (deployment profile → flex credits)

---

## Deployment – 5 Phases

### Phase 1a: Infrastructure + Panorama

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

```bash
cd phase2-panorama-config/
cp terraform.tfvars.example terraform.tfvars
# Edit: panorama_password, panorama_serial_number, external_lb_public_ip
cd ..

bash scripts/configure-panorama.sh
```

The script automatically:
1. ⏳ Starts Bastion tunnel to Panorama
2. ✅ Sets hostname via XML API + commit
3. ✅ Sets serial number (operational mode: `set serial-number`) + commit + `request license fetch`
4. ✅ Generates vm-auth-key → saves to `panorama_vm_auth_key.auto.tfvars` (auto-loaded!)
5. ✅ Creates Template Stack, Device Group, interfaces (DHCP), zones, routes, NAT, security
6. ✅ Final commit
7. 🧹 Closes Bastion tunnel

### Phase 1b: Deploy Firewalls

```bash
# vm-auth-key is auto-loaded from panorama_vm_auth_key.auto.tfvars — zero manual edit!
terraform apply \
  -target=module.bootstrap \
  -target=module.loadbalancer \
  -target=module.firewall \
  -target=module.routing \
  -target=module.frontdoor \
  -target=module.app1_app
```

FW boot sequence: PAN-OS reads bootstrap from Azure File Share → activates license (auth code → dynamic serial number) → connects to Panorama.

### Phase 2b: Register FWs on Panorama (automated)

```bash
bash scripts/register-fw-panorama.sh
```

The script automatically:
1. Opens Bastion tunnels to FW1, FW2, Panorama
2. Reads FW serial numbers via XML API (`show system info`)
3. Sets auth-key on FWs (`request authkey set`)
4. Registers serials on Panorama: `mgt-config devices` + Device Group + Template Stack
5. Commits on Panorama
6. Closes all tunnels

After ~60s, FWs appear as **connected** in Panorama → `show devices connected`.

### Phase 3: DC (optional, independent)

```bash
terraform apply -target=module.app2_dc
```

---

## Bootstrap – How It Works

FW bootstrap uses **Azure File Share** per [PAN-OS docs](https://docs.paloaltonetworks.com/vm-series/11-1/vm-series-deployment/bootstrap-the-vm-series-firewall/bootstrap-the-vm-series-firewall-in-azure):

```
Storage Account (default_action=Deny, service endpoint + NAT GW IP)
  └── File Share: "bootstrap"
        ├── fw1/
        │   ├── config/init-cfg.txt    ← hostname, panorama-server, tplname, dgname, vm-auth-key
        │   ├── license/authcodes      ← BYOL auth code (e.g. D5541146)
        │   ├── content/               ← (empty)
        │   └── software/              ← (empty)
        └── fw2/ (same structure)
```

`init-cfg.txt` content:
```
type=dhcp-client
hostname=fw1-transit-hub
panorama-server=10.255.0.4
tplname=Transit-VNet-Stack
dgname=Transit-VNet-DG
vm-auth-key=2:AZyNep...    ← from Phase 2a
dns-primary=168.63.129.16
authcodes=D5541146
```

Bootstrap pointer (`userData`, base64):
```
storage-account=sapanosbstrapXXXXXXXX
access-key=<SA primary access key>
file-share=bootstrap
share-directory=fw1
```

---

## Panorama Activation – How It Works

| Step | Phase | Method | Action |
|------|-------|--------|--------|
| 1 | Phase 1a | Terraform (azurerm) | Creates Panorama VM – boots with default hostname |
| 2 | Phase 2a | XML API (config mode) | Sets hostname + commit |
| 3 | Phase 2a | XML API (operational) | `set serial-number` + commit + `request license fetch` |
| 4 | Phase 2a | XML API (operational) | Generates vm-auth-key → auto.tfvars |
| 5 | Phase 2a | panos provider | Template Stack, DG, interfaces (DHCP), zones, routes, NAT, security |
| 6 | Phase 2b | XML API (config mode) | Adds FW serials to `mgt-config devices` + DG + TS |

**Serial number** is set via operational mode (not config mode):
```
CLI:     set serial-number 000710041165
XML API: type=op, cmd=<set><serial-number>SERIAL</serial-number></set>
```

**FW serial numbers** are dynamic — generated when auth code activates on each FW. They must be read after FW boot and registered on Panorama:
```
CLI (configure mode on Panorama):
  set mgt-config devices 007957000843524
  set device-group Transit-VNet-DG devices 007957000843524
  set template-stack Transit-VNet-Stack devices 007957000843524
  commit
```

**Interface DHCP**: ethernet1/1 (untrust) and ethernet1/2 (trust) use DHCP. Azure DHCP is deterministic — always returns the exact IP configured on the NIC resource in Terraform.

---

## Key Variables

### Phase 1 – root terraform.tfvars

| Variable | Description |
|----------|-------------|
| `hub_subscription_id` | Hub subscription (Management + Transit VNet) |
| `admin_password` | Password for Panorama and FW (min 12 chars) |
| `panorama_vm_auth_key` | Auto-generated in Phase 2a (auto.tfvars) |
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
```

### Panorama license fetch fails
```bash
# Check serial number (operational mode — NOT configure mode!)
admin@panorama> show system info | match serial

# Manual serial set (operational mode)
admin@panorama> set serial-number 000710041165

# Check internet access (NAT Gateway required)
admin@panorama> ping host 8.8.8.8 source 10.255.0.4

# Fetch license
admin@panorama> request license fetch
```

### FW not connecting to Panorama
```bash
# On FW — check status
admin@fw1> show panorama-status
admin@fw1> show system bootstrap status

# Manual auth-key set (if bootstrap didn't include it)
admin@fw1> request authkey set 2:AZyNep...

# On Panorama — register FW serial (configure mode)
admin@panorama# set mgt-config devices 007957000843524
admin@panorama# set device-group Transit-VNet-DG devices 007957000843524
admin@panorama# set template-stack Transit-VNet-Stack devices 007957000843524
admin@panorama# commit

# Verify
admin@panorama> show devices connected
```

### NAT commit fails (interface has no IP)
Interfaces must have DHCP enabled in Panorama Template. This is configured automatically by Phase 2a. If missing:
```bash
# On Panorama (configure mode)
admin@panorama# set template Transit-VNet-Template config devices entry localhost.localdomain network interface ethernet ethernet1/1 layer3 dhcp-client enable yes
admin@panorama# set template Transit-VNet-Template config devices entry localhost.localdomain network interface ethernet ethernet1/2 layer3 dhcp-client enable yes
admin@panorama# commit
```

---

## Project Structure

```
azure_ha_project/
├── main.tf / variables.tf / outputs.tf    Root module (5-phase deployment)
├── modules/
│   ├── bootstrap/          SA + Azure File Share + init-cfg.txt
│   ├── panorama/           Panorama VM (no bootstrap)
│   ├── panorama_config/    panos provider: Template, DG, policies (DHCP interfaces)
│   ├── firewall/           VM-Series HA pair + userData bootstrap
│   ├── networking/         VNets, subnets, NSGs, peerings, Bastion, NAT GW
│   ├── loadbalancer/       External + Internal Standard LB
│   ├── routing/            UDR Route Tables
│   ├── frontdoor/          Azure Front Door Premium
│   ├── spoke1_app/         Ubuntu + Apache
│   └── spoke2_dc/          Windows Server DC
├── phase2-panorama-config/ Separate workspace: Panorama API + panos config
├── scripts/
│   ├── configure-panorama.sh       Phase 2a (auto Bastion tunnel + terraform apply)
│   ├── register-fw-panorama.sh     Phase 2b (auto serial read + Panorama register)
│   ├── check-panorama.sh           Status + quick Bastion commands
│   ├── generate-vm-auth-key.sh     Standalone vm-auth-key generator
│   └── fix-drift.sh                Fix terraform drift after FW restart
└── optional/dc-promote/    Manual DC promotion to domain controller
```

---

## License

MIT – see [LICENSE](LICENSE)
