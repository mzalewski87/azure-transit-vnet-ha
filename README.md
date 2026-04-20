# Azure Transit VNet – Palo Alto VM-Series HA Reference Architecture

Kompletna infrastruktura IaaC (Terraform) dla architektury referencyjnej **Palo Alto Networks Azure Transit VNet** z parą VM-Series w konfiguracji Active/Passive HA.

> **Źródło:** [PANW Azure Transit VNet Deployment Guide](https://www.paloaltonetworks.com/apps/pan/public/downloadResource?pagePath=/content/pan/en_US/resources/guides/azure-transit-vnet-deployment-guide)

---

## Architektura

```
  ┌─────────────────────────────────────────────────────────────────────────────────────────────┐
  │  AZURE                                                                                       │
  │                                                                                             │
  │  ┌───────────────────────────── Management VNet (10.255.0.0/16) ──────────────────────────┐ │
  │  │                                                                                         │ │
  │  │   ┌─────────────────────────────────┐   ┌─────────────────────────────────────────┐   │ │
  │  │   │  snet-management (10.255.0.0/24)│   │  AzureBastionSubnet (10.255.1.0/26)     │   │ │
  │  │   │                                 │   │                                         │   │ │
  │  │   │   ┌─────────────────────────┐   │   │   ┌───────────────────────────────┐    │   │ │
  │  │   │   │  Panorama               │   │   │   │  Azure Bastion Standard        │    │   │ │
  │  │   │   │  10.255.0.4 (static)    │   │   │   │  (reaches ALL peered VNets)   │    │   │ │
  │  │   │   │  BYOL, 16vCPU/64GB RAM  │   │   │   │  pip-bastion-management       │    │   │ │
  │  │   │   │  2TB Premium SSD logs   │   │   │   └───────────────────────────────┘    │   │ │
  │  │   │   └─────────────────────────┘   │   │                                         │   │ │
  │  │   └─────────────────────────────────┘   └─────────────────────────────────────────┘   │ │
  │  │                         ↑ HA1 + Panorama→FW                      ↑ HTTPS/SSH           │ │
  │  │            NAT GW       │                                         │ Admin Acces          │ │
  │  │         (outbound)      │                              Internet browsers/CLI             │ │
  │  └─────────────────────────┼─────────────────────────────────────────────────────────────-┘ │
  │                            │ VNet Peering (all ↔ all)                                        │
  │  ┌─────────────────────────┼──── Transit Hub VNet (10.110.0.0/16) ─────────────────────────┐ │
  │  │                         │                                                                │ │
  │  │  snet-mgmt (10.110.255.0/24) ←── FW eth0 (management + HA1 heartbeat)                  │ │
  │  │  ┌────────────────────────────────────────────────────────────────────────────────────┐ │ │
  │  │  │  FW1 (Active)  10.110.255.4   FW2 (Passive) 10.110.255.5                          │ │ │
  │  │  │  VM-Series BYOL 8vCPU         VM-Series BYOL 8vCPU                                │ │ │
  │  │  └──────────┬───────────────────────────┬───────────────────────────────────────────-┘ │ │
  │  │             │ eth1/1                     │ eth1/2                                        │ │
  │  │  ┌──────────▼──────────────┐  ┌──────────▼──────────────────────────────────────────┐  │ │
  │  │  │ snet-public             │  │ snet-private (10.110.0.0/24)                         │  │ │
  │  │  │ (10.110.129.0/24)       │  │                                                      │  │ │
  │  │  │                         │  │  Internal Standard LB                                │  │ │
  │  │  │  External Standard LB ◄─┤  │  Frontend: 10.110.0.21 (static)                     │  │ │
  │  │  │  pip-external-lb        │  │  Backend: FW1 trust NIC + FW2 trust NIC              │  │ │
  │  │  └──────────┬──────────────┘  │  ← UDR next-hop dla App1 i App2                      │  │ │
  │  │             │                 └──────────────────────────────────────────────────────┘  │ │
  │  │  ┌──────────▼──────────────┐                                                            │ │
  │  │  │ snet-ha (10.110.128.0/24)│  ← FW eth1/3 HA2 data sync                              │ │
  │  │  └─────────────────────────┘                                                            │ │
  │  └────────────────────────────────────────────────────────────────────────────────────────┘ │
  │                                                                                             │
  │  ┌──── App1 VNet (10.112.0.0/16) ────────────┐  ┌──── App2 VNet (10.113.0.0/16) ────────┐ │
  │  │  snet-workload (10.112.0.0/24)             │  │  snet-workload (10.113.0.0/24)         │ │
  │  │  Ubuntu 22.04 + Apache  10.112.0.4         │  │  Windows Server 2022 DC  10.113.0.4   │ │
  │  │  UDR: 0.0.0.0/0 → 10.110.0.21 (ILB)       │  │  UDR: 0.0.0.0/0 → 10.110.0.21 (ILB)  │ │
  │  └────────────────────────────────────────────┘  └────────────────────────────────────────┘ │
  │                                                                                             │
  │  ┌── Azure Front Door Premium ─────────────────────────────────────────────────────────┐   │
  │  │  HTTP/HTTPS → pip-external-lb → External LB → FW eth1/1 → FW policy → ILB → App1   │   │
  │  └─────────────────────────────────────────────────────────────────────────────────────┘   │
  └─────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Topology i przepływy ruchu

### VNet Topology

| VNet | CIDR | Przeznaczenie | Subskrypcja |
|------|------|---------------|-------------|
| Management VNet | 10.255.0.0/16 | Panorama + Azure Bastion | Hub |
| Transit Hub VNet | 10.110.0.0/16 | VM-Series FW HA pair | Hub |
| App1 VNet | 10.112.0.0/16 | Workloady aplikacyjne | Spoke1 |
| App2 VNet | 10.113.0.0/16 | Windows DC / dodatkowe workloady | Spoke2 |

### Subnety Transit Hub VNet

| Subnet | CIDR | Interface FW | Opis |
|--------|------|-------------|------|
| snet-mgmt | 10.110.255.0/24 | eth0 | Management, HA1 heartbeat |
| snet-public | 10.110.129.0/24 | eth1/1 | Untrust, inbound z External LB |
| snet-private | 10.110.0.0/24 | eth1/2 | Trust, outbound do App VNetów |
| snet-ha | 10.110.128.0/24 | eth1/3 | HA2 data synchronisation |

### VNet Peerings

| Peering | Kierunek | Cel |
|---------|---------|-----|
| Management ↔ Transit | Bidirectional | Panorama → FW management (TCP/3978, 28443) |
| Management ↔ App1 | Bidirectional | Bastion → App1 VMs |
| Management ↔ App2 | Bidirectional | Bastion → App2/DC VMs |
| Transit ↔ App1 | Bidirectional | UDR traffic przez FW |
| Transit ↔ App2 | Bidirectional | UDR traffic przez FW |

### Przepływy ruchu

#### Inbound (Internet → Aplikacja)
```
Internet → Azure Front Door Premium
→ pip-external-lb (Public IP)
→ External Standard LB (TCP 80/443)
→ FW eth1/1 (snet-public) [active FW]
→ Security Policy (inspect, NAT)
→ FW eth1/2 (snet-private)
→ Internal Standard LB (10.110.0.21)
→ App1 (10.112.0.4)
```

#### Outbound (Aplikacja → Internet)
```
App1/App2 VM
→ UDR: 0.0.0.0/0 → 10.110.0.21 (Internal LB)
→ Internal LB → FW eth1/2 (snet-private) [active FW]
→ Security Policy (inspect)
→ FW eth1/1 (snet-public)
→ External LB SNAT → Internet
```

#### East-West (App1 ↔ App2)
```
App1 VM
→ UDR: 10.113.0.0/16 → 10.110.0.21 (Internal LB)
→ Internal LB → FW (inspect East-West policy)
→ Internal LB → App2 VM
```

#### Management (Bastion → FW/Panorama)
```
Operator Browser → Azure Bastion (pip-bastion-management)
→ IpConnect SSH: FW eth0 (10.110.255.4/5) lub Panorama (10.255.0.4)
→ Bastion Tunnel HTTPS: panos Terraform provider (port 44300 → 443)
```

---

## Komponenty

### Azure Bastion Standard (Management VNet)
- Jeden Bastion dla wszystkich VNetów (Standard tier = cross-VNet access via peering)
- `tunneling_enabled = true` → wymagane dla `az network bastion tunnel --target-resource-id`
- Dostęp do: Panorama (10.255.0.4), FW1 (10.110.255.4), FW2 (10.110.255.5), DC (10.113.0.4)

### Panorama (Management VNet, 10.255.0.4)
- Standard_D16s_v3 (16 vCPU / 64 GB RAM)
- 2TB Premium SSD data disk dla logów
- Bootstrap: **bezpośrednia treść init-cfg w `customData`** (NIE SA storage pointer)
- Outbound Internet przez NAT Gateway (licencja, content updates)

### VM-Series FW HA Pair (Transit VNet)
- 2x Standard_D8s_v3 (8 vCPU / 32 GB RAM each)
- Active/Passive HA – FW1 Active, FW2 Passive
- Bootstrap przez Azure Storage Account (SA pointer w `customData`)
- Managed Identity dla dostępu do Bootstrap SA (bez storage access key)
- Licencja BYOL – aktivacja przez init-cfg authcodes=

### Load Balancers
- **External Standard LB**: Public IP (zonal 1/2/3), frontend inbound z AFD
- **Internal Standard LB**: 10.110.0.21, HA port rule (all ports), next-hop dla UDR

### Azure Front Door Premium
- HTTPS termination, WAF, global load balancing
- Origin: pip-external-lb

### UDR (User Defined Routes)
- App1 snet-workload: 0.0.0.0/0 → 10.110.0.21 (Internal LB)
- App2 snet-workload: 0.0.0.0/0 → 10.110.0.21 (Internal LB)
- East-West: osobne trasy dla obu VNetów

---

## Wymagania wstępne

### Narzędzia
```bash
terraform >= 1.5.0
azure-cli >= 2.50.0
python3 >= 3.8
curl, git
```

### Azure
- 3 subskrypcje (lub 1 dla single-sub demo)
- Service Principal lub Azure CLI logged in
- Uprawnienia: `Contributor` + `User Access Administrator` (dla RBAC)
- Marketplace agreement dla VM-Series i Panorama (auto-accept w module)

### Licencje Palo Alto (z CSP Portal – support.paloaltonetworks.com)
- 1x Panorama BYOL auth code (`panorama_auth_code`)
- 2x VM-Series BYOL auth codes (lub 1 shared `fw_auth_code`)
- Serial number Panoramy (`panorama_serial_number`)

---

## Wdrożenie – kolejność

### KROK 0: Przygotowanie

```bash
git clone <this-repo>
cd azure_ha_project

cp terraform.tfvars.example terraform.tfvars
# Edytuj terraform.tfvars – uzupełnij subscription IDs, hasła, auth codes

terraform init
```

### KROK 1a: Infrastruktura bazowa (Management VNet + Panorama)

```bash
# Utwórz Resource Groups, networking, bootstrap SA, Panorama, DC
terraform apply \
  -target=azurerm_resource_group.hub \
  -target=azurerm_resource_group.app1 \
  -target=azurerm_resource_group.app2 \
  -target=module.networking \
  -target=module.bootstrap \
  -target=module.panorama \
  -target=module.app2_dc
```

Poczekaj ~15 minut na boot Panoramy. Sprawdź przez Bastion:

```bash
# Połącz się do Panoramy przez Bastion SSH
az network bastion ssh \
  --name bastion-management \
  --resource-group rg-transit-hub \
  --target-ip-address 10.255.0.4 \
  --auth-type password \
  --username panadmin

# Sprawdź status systemu
admin@panorama> show system info | match serial
admin@panorama> show system licenses
```

**Jeśli bootstrap nie zadziałał (hostname = vm-panorama):**
```bash
# Manualnie ustaw hostname
admin@panorama# set deviceconfig system hostname panorama-transit-hub
admin@panorama# commit

# Aktywuj licencję
admin@panorama> request license activate auth-code <TWOJ_AUTH_CODE>
```

### KROK 2: Konfiguracja Panoramy (Template Stack, Device Group, reguły)

W dwóch terminalach:

**Terminal 1 – Bastion tunnel:**
```bash
PANORAMA_ID=$(terraform output -raw panorama_vm_id)
az network bastion tunnel \
  --name bastion-management \
  --resource-group rg-transit-hub \
  --target-resource-id "$PANORAMA_ID" \
  --resource-port 443 --port 44300
# Zostaw otwarty – tunnel aktywny
```

**Terminal 2 – Terraform phase2:**
```bash
cd phase2-panorama-config/
cp terraform.tfvars.example terraform.tfvars
# Uzupełnij panorama_url = "https://127.0.0.1:44300"
terraform init && terraform apply
```

Phase 2 tworzy w Panoramie:
- Template Stack: `Transit-VNet-Stack`
- Device Group: `Transit-VNet-DG`
- Interface config (eth0/1/2/3, IP addressing)
- Zone config (mgmt, untrust, trust, ha)
- Security policies: Inbound, Outbound, East-West
- NAT policies

### KROK 1b: Generowanie VM Auth Key + wdrożenie FW

```bash
# Zamknij tunnel z KROK 2, otwórz SSH do Panoramy
az network bastion ssh \
  --name bastion-management \
  --resource-group rg-transit-hub \
  --target-ip-address 10.255.0.4 \
  --auth-type password --username panadmin

# Wygeneruj vm-auth-key (ważny 168h = 7 dni)
admin@panorama> request vm-auth-key generate lifetime 168
# Skopiuj klucz z outputu

# LUB użyj skryptu (wymaga Bastion tunnel na port 44300):
PANORAMA_IP=127.0.0.1 PANORAMA_PORT=44300 ./scripts/generate-vm-auth-key.sh
```

Dodaj klucz do terraform.tfvars:
```hcl
panorama_vm_auth_key = "2:XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
```

```bash
# Zaktualizuj bootstrap SA z nowym vm-auth-key w FW init-cfg
terraform apply -target=module.bootstrap

# Wdróż FW, LB, routing, Front Door, App
terraform apply \
  -target=module.loadbalancer \
  -target=module.firewall \
  -target=module.routing \
  -target=module.frontdoor \
  -target=module.app1_app
```

### KROK 3: Weryfikacja

```bash
# Sprawdź output
terraform output

# Test inbound przez Front Door
curl -s "https://$(terraform output -raw frontdoor_endpoint)"

# Test FW rejestracji w Panoramie (przez Bastion SSH do Panoramy):
admin@panorama> show devices connected
```

---

## Dostęp przez Azure Bastion

### SSH do Panoramy lub FW
```bash
# Panorama
az network bastion ssh \
  --name bastion-management \
  --resource-group rg-transit-hub \
  --target-ip-address 10.255.0.4 \
  --auth-type password --username panadmin

# FW1
az network bastion ssh \
  --name bastion-management \
  --resource-group rg-transit-hub \
  --target-ip-address 10.110.255.4 \
  --auth-type password --username panadmin
```

### HTTPS GUI (Bastion tunnel)
```bash
# Terminal 1 – otwórz tunnel
VM_ID=$(az vm show -g rg-transit-hub -n vm-panorama --query id -o tsv)
az network bastion tunnel \
  --name bastion-management \
  --resource-group rg-transit-hub \
  --target-resource-id "$VM_ID" \
  --resource-port 443 --port 44300

# Terminal 2 – otwórz w przeglądarce
open https://localhost:44300
```

### RDP do Windows DC
```bash
DC_ID=$(terraform output -raw dc_vm_id)
az network bastion rdp \
  --name bastion-management \
  --resource-group rg-transit-hub \
  --target-resource-id "$DC_ID"
```

---

## Zmienne konfiguracyjne

### Kluczowe zmienne

| Zmienna | Domyślna wartość | Opis |
|---------|-----------------|------|
| `hub_subscription_id` | (required) | Subskrypcja Hub (Management VNet + Transit VNet) |
| `spoke1_subscription_id` | (required) | Subskrypcja App1 |
| `spoke2_subscription_id` | (required) | Subskrypcja App2 |
| `admin_password` | (required) | Hasło Panoramy i FW (min 12 znaków) |
| `panorama_auth_code` | `""` | Auth code BYOL Panoramy z CSP Portal |
| `panorama_serial_number` | `""` | Serial number Panoramy z CSP Portal |
| `panorama_vm_auth_key` | `""` | Device Registration Key (wygeneruj po KROK 1a) |
| `fw_auth_code` | `""` | Auth code VM-Series BYOL |
| `terraform_operator_ips` | `[]` | Twoje publiczne IP (dla Bootstrap SA access) |

### IP Addressing (domyślne)

| Zasób | IP |
|------|----|
| Panorama | 10.255.0.4 |
| FW1 mgmt (eth0) | 10.110.255.4 |
| FW2 mgmt (eth0) | 10.110.255.5 |
| FW1 untrust (eth1/1) | 10.110.129.4 |
| FW2 untrust (eth1/1) | 10.110.129.5 |
| FW1 trust (eth1/2) | 10.110.0.4 |
| FW2 trust (eth1/2) | 10.110.0.5 |
| Internal LB | 10.110.0.21 |
| App1 VM | 10.112.0.4 |
| DC (App2) | 10.113.0.4 |

---

## Struktura repozytorium

```
azure_ha_project/
├── main.tf                         # Root module – orchestracja wszystkich modułów
├── variables.tf                    # Zmienne root module
├── outputs.tf                      # Outputy (IPs, resource IDs, Bastion info)
├── terraform.tfvars                # Wartości zmiennych (NIE commitować z danymi!)
├── terraform.tfvars.example        # Przykładowy plik z placeholderami
├── providers.tf                    # Providery azurerm (hub, spoke1, spoke2)
│
├── modules/
│   ├── networking/                 # Management VNet + Transit VNet + App VNets
│   │   ├── main.tf                 # VNets, Subnets, NSGs, Peerings, Bastion, NAT GW
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── bootstrap/                  # Bootstrap SA dla VM-Series FW
│   │   ├── main.tf                 # SA, kontenery, blobs FW1/FW2
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── templates/
│   │       └── init-cfg.txt.tpl    # FW bootstrap config (vm-auth-key opcjonalny)
│   ├── panorama/                   # Panorama VM (Management VNet)
│   │   ├── main.tf                 # VM, NIC, disk, direct init-cfg customData
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── templates/
│   │       └── panorama-init-cfg.txt.tpl
│   ├── firewall/                   # VM-Series FW HA pair
│   │   ├── main.tf                 # 2x VMs, 4x NICs each, Availability Set
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── loadbalancer/               # External LB + Internal LB
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── routing/                    # UDR Route Tables (App1, App2)
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── frontdoor/                  # Azure Front Door Premium
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── spoke1_app/                 # App1 – Ubuntu + Apache Hello World
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── spoke2_dc/                  # App2 – Windows Server 2022 DC
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── dc-setup.ps1.tpl       # PowerShell DC promotion script
│   └── panorama_config/           # (dodatkowy) Panorama konfiguracja przez panos provider
│
├── phase2-panorama-config/         # ODRĘBNY workspace Terraform
│   ├── main.tf                     # panos provider – Template Stack, DG, policies
│   ├── variables.tf
│   ├── providers.tf
│   ├── outputs.tf
│   └── terraform.tfvars.example
│
├── optional/
│   └── dc-promote/                 # Opcjonalna ręczna promocja DC (DSC)
│
└── scripts/
    ├── generate-vm-auth-key.sh     # Automatyczne generowanie vm-auth-key z Panoramy
    ├── check-panorama.sh           # Weryfikacja statusu Panoramy
    └── fix-drift.sh                # Naprawa driftu konfiguracji
```

---

## Ważne uwagi techniczne

### Bootstrap Panoramy vs VM-Series FW

| | Panorama | VM-Series FW |
|---|----------|-------------|
| `customData` format | Bezpośrednia treść init-cfg (base64) | SA storage pointer |
| Przykład | `type=dhcp-client\nhostname=...` | `storage-account=sa...\nfile-share=bootstrap\n...` |
| Źródło | `templatefile("panorama-init-cfg.txt.tpl")` | `module.bootstrap.fw1_custom_data` |

### vm-auth-key (Device Registration Auth Key)

- **Wymagany** dla automatycznej rejestracji FW w Panoramie przy starcie
- Generowany w Panoramie AFTER aktywacji licencji
- Wbudowany w FW init-cfg (`vm-auth-key=`)
- Ważny 168h (7 dni) domyślnie – ustaw przed wdrożeniem FW
- PAN-OS 12.x: alternatywnie Device Certificate (bez vm-auth-key)

### NSG reguły

- **snet-mgmt (Transit)**: SSH/HTTPS tylko z Management VNet (Bastion range 10.255.0.0/16)
- **snet-public (Transit)**: Allow All (PAN-OS inspektuje ruch)
- **snet-private (Transit)**: Allow All (PAN-OS enforces policy)
- **snet-management (Management VNet)**: SSH/HTTPS z AzureBastionSubnet, Panorama↔FW na 3978/28443

### High Availability

- **HA1** (heartbeat): przez eth0 (snet-mgmt), 10.110.255.4 ↔ 10.110.255.5
- **HA2** (data sync): przez eth1/3 (snet-ha), 10.110.128.x ↔ 10.110.128.x
- **Failover**: Azure LB health probe → automatyczny failover do FW2
- **Session sync**: HA2 synchronizuje sesje → bezstanowy failover

---

## Troubleshooting

### Panorama hostname = vm-panorama (bootstrap nie zadziałał)

```bash
# 1. Sprawdź co jest w customData VM
az vm show -g rg-transit-hub -n vm-panorama \
  --query 'osProfile.customData' -o tsv | base64 -d

# 2. Jeśli puste → problem z Terraform provider (znany bug azurerm < 3.85)
# Rozwiązanie: ustaw ręcznie przez Bastion SSH
az network bastion ssh --name bastion-management \
  --resource-group rg-transit-hub \
  --target-ip-address 10.255.0.4 \
  --auth-type password --username panadmin

admin@panorama# set deviceconfig system hostname panorama-transit-hub
admin@panorama# commit

# 3. Aktywacja licencji
admin@panorama> request license activate auth-code XXXX-XXXX-XXXX-XXXX
```

### FW nie rejestruje się w Panoramie

```bash
# SSH do FW przez Bastion
az network bastion ssh --name bastion-management \
  --resource-group rg-transit-hub \
  --target-ip-address 10.110.255.4 \
  --auth-type password --username panadmin

# Sprawdź status Panoramy
admin@fw1> show panorama-status

# Sprawdź bootstrap log
admin@fw1> debug bootstrap detail

# Manualnie połącz z Panoramą
admin@fw1# set deviceconfig system panorama-server 10.255.0.4
admin@fw1# commit
```

### vm-auth-key expired

```bash
# Wygeneruj nowy klucz
az network bastion ssh --name bastion-management \
  --resource-group rg-transit-hub \
  --target-ip-address 10.255.0.4 \
  --auth-type password --username panadmin

admin@panorama> request vm-auth-key generate lifetime 168

# Zaktualizuj terraform.tfvars i odśwież bootstrap SA
terraform apply -target=module.bootstrap
```

---

## Licencja

MIT – patrz [LICENSE](LICENSE)

---

## Autor

Architektura referencyjna na podstawie:
- [PANW Azure Transit VNet Deployment Guide](https://www.paloaltonetworks.com/apps/pan/public/downloadResource?pagePath=/content/pan/en_US/resources/guides/azure-transit-vnet-deployment-guide)
- [VM-Series Deployment Guide for Azure](https://docs.paloaltonetworks.com/vm-series/11-0/vm-series-deployment/set-up-the-vm-series-firewall-on-azure)
- [Panorama Administrator's Guide](https://docs.paloaltonetworks.com/panorama/10-2/panorama-admin)
