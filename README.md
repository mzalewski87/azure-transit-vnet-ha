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
  │  │            NAT GW       │                                         │ Admin Access         │ │
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
→ SSH (--target-resource-id): FW eth0 (10.110.255.4/5) lub Panorama (10.255.0.4)
→ Bastion Tunnel HTTPS: panos Terraform provider (port 44300 → 443)
```

---

## Komponenty

### Azure Bastion Standard (Management VNet)
- Jeden Bastion dla wszystkich VNetów (Standard tier = cross-VNet access via peering)
- `tunneling_enabled = true` → wymagane dla `az network bastion tunnel`
- `ip_connect_enabled = true` → wymagane dla `az network bastion ssh --target-ip-address`
- Dostęp do: Panorama (10.255.0.4), FW1 (10.110.255.4), FW2 (10.110.255.5), DC (10.113.0.4)

### Panorama (Management VNet, 10.255.0.4)
- Standard_D16s_v3 (16 vCPU / 64 GB RAM)
- 2TB Premium SSD data disk dla logów
- **Brak bootstrap (custom_data)** – Panorama startuje z domyślnym hostname `localhost.localdomain`
- Konfiguracja (hostname, licencja, Template Stack, Device Group, policies) → **Phase 2 (XML API)**
- Outbound Internet przez NAT Gateway (licencja, content updates)

### VM-Series FW HA Pair (Transit VNet)
- 2x Standard_D8s_v3 (8 vCPU / 32 GB RAM each)
- Active/Passive HA – FW1 Active, FW2 Passive
- Bootstrap przez Azure Storage Account (SA pointer w `customData`)
- Managed Identity dla dostępu do Bootstrap SA (bez storage access key)
- Licencja BYOL – aktywacja przez init-cfg `authcodes=` przy starcie

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

### Licencje Palo Alto (z CSP Portal – my.paloaltonetworks.com)
- 1x Panorama BYOL auth code → zarejestruj na CSP Portal → uzyskaj **Serial Number**
- 2x VM-Series BYOL auth codes (lub 1 shared `fw_auth_code`)

---

## Wdrożenie – kolejność

### KROK 0: Przygotowanie

```bash
git clone <this-repo>
cd azure_ha_project

cp terraform.tfvars.example terraform.tfvars
# Edytuj terraform.tfvars – uzupełnij subscription IDs, hasła
# UWAGA: panorama_serial_number jest w phase2-panorama-config/terraform.tfvars

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

Poczekaj ~15 minut na boot Panoramy. Opcjonalnie sprawdź dostępność przez Bastion:

```bash
# Metoda A: przez resource ID (zawsze działa)
PANORAMA_ID=$(terraform output -raw panorama_vm_id)
az network bastion ssh \
  --name bastion-management \
  --resource-group rg-transit-hub \
  --target-resource-id "$PANORAMA_ID" \
  --auth-type password \
  --username panadmin

# Metoda B: przez IP (po terraform apply, ip_connect_enabled=true)
az network bastion ssh \
  --name bastion-management \
  --resource-group rg-transit-hub \
  --target-ip-address 10.255.0.4 \
  --auth-type password \
  --username panadmin

# Sprawdź status systemu (tryb operacyjny: prompt = admin@panorama>)
admin@panorama> show system info
admin@panorama> show license
```

> **Uwaga:** Na tym etapie Panorama nie ma jeszcze licencji ani hostname. Konfiguracja następuje w KROK 2 (Phase 2) automatycznie.

### KROK 2: Aktywacja licencji + konfiguracja Panoramy (Phase 2)

**Przed uruchomieniem Phase 2 – zarejestruj Panoramę na CSP Portal:**

```
1. Zaloguj się: my.paloaltonetworks.com
2. Assets → Add Product → wpisz auth-code Panoramy
3. Wybierz typ: Panorama → CSP przypisze Serial Number (format: 007300XXXXXXX)
4. Skopiuj Serial Number
```

W dwóch terminalach:

**Terminal 1 – Bastion tunnel (zostaw otwarty przez cały czas Phase 2):**
```bash
PANORAMA_ID=$(terraform output -raw panorama_vm_id)
az network bastion tunnel \
  --name bastion-management \
  --resource-group rg-transit-hub \
  --target-resource-id "$PANORAMA_ID" \
  --resource-port 443 --port 44300
# Terminal BLOKUJĄCY – nie zamykaj!
```

**Terminal 2 – Terraform Phase 2:**
```bash
cd phase2-panorama-config/
cp terraform.tfvars.example terraform.tfvars

# Uzupełnij terraform.tfvars:
#   panorama_password      = "haslo-z-phase1"
#   panorama_serial_number = "007300XXXXXXX"   ← z CSP Portal
#   external_lb_public_ip  = "X.X.X.X"         ← terraform output external_lb_public_ip

terraform init && terraform apply
```

Phase 2 wykonuje automatycznie:
1. ⏳ Czeka aż Panorama API odpowie (max 20 min)
2. ✅ Ustawia hostname `panorama-transit-hub` przez XML API + commit
3. ✅ Ustawia serial number przez XML API + commit
4. ✅ `request license fetch` – Panorama pobiera licencję z serwera PANW
5. ✅ Tworzy Template Stack, Device Group, Interface/Zone/Route/Security/NAT config (panos provider)
6. ✅ Commit końcowy Panoramy

### KROK 1b: Generowanie VM Auth Key + wdrożenie FW

Po aktywacji licencji Panoramy, wygeneruj klucz rejestracyjny dla VM-Series:

```bash
# Opcja A: przez Bastion SSH
PANORAMA_ID=$(terraform output -raw panorama_vm_id)
az network bastion ssh \
  --name bastion-management \
  --resource-group rg-transit-hub \
  --target-resource-id "$PANORAMA_ID" \
  --auth-type password --username panadmin

# Wygeneruj vm-auth-key (ważny 168h = 7 dni)
admin@panorama> request vm-auth-key generate lifetime 168
# Skopiuj klucz z outputu (format: 2:XXXXXXXXX...)

# Opcja B: przez skrypt (wymaga Bastion tunnel na port 44300)
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

# Sprawdź rejestrację FW w Panoramie (przez Bastion SSH do Panoramy)
admin@panorama> show devices connected
```

---

## Dostęp przez Azure Bastion

```bash
# Helper script – sprawdza status i pokazuje wszystkie komendy
./scripts/check-panorama.sh

# HTTPS tunel do Panoramy (dla GUI lub Phase 2)
./scripts/check-panorama.sh --tunnel

# RDP tunel do DC
./scripts/check-panorama.sh --rdp
```

### SSH do Panoramy lub FW (przez resource ID – zawsze działa)
```bash
# Panorama
PANORAMA_ID=$(terraform output -raw panorama_vm_id)
az network bastion ssh \
  --name bastion-management \
  --resource-group rg-transit-hub \
  --target-resource-id "$PANORAMA_ID" \
  --auth-type password --username panadmin

# FW1
FW1_ID=$(terraform output -raw fw1_vm_id)
az network bastion ssh \
  --name bastion-management \
  --resource-group rg-transit-hub \
  --target-resource-id "$FW1_ID" \
  --auth-type password --username panadmin
```

### SSH przez IP (po `terraform apply -target=module.networking`)
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

### HTTPS GUI Panoramy (Bastion tunnel)
```bash
# Terminal 1 – otwórz tunnel
PANORAMA_ID=$(terraform output -raw panorama_vm_id)
az network bastion tunnel \
  --name bastion-management \
  --resource-group rg-transit-hub \
  --target-resource-id "$PANORAMA_ID" \
  --resource-port 443 --port 44300

# Terminal 2 – otwórz w przeglądarce
open https://localhost:44300
# Kliknij: ADVANCED → Proceed (certyfikat self-signed)
```

### RDP do Windows DC
```bash
DC_ID=$(terraform output -raw dc_vm_id)
az network bastion tunnel \
  --name bastion-management \
  --resource-group rg-transit-hub \
  --target-resource-id "$DC_ID" \
  --resource-port 3389 --port 33389
# Następnie: mstsc /v:localhost:33389 (Windows) lub Microsoft Remote Desktop (macOS)
```

---

## Zmienne konfiguracyjne

### Phase 1 – root terraform.tfvars

| Zmienna | Domyślna wartość | Opis |
|---------|-----------------|------|
| `hub_subscription_id` | (required) | Subskrypcja Hub (Management VNet + Transit VNet) |
| `spoke1_subscription_id` | (required) | Subskrypcja App1 |
| `spoke2_subscription_id` | (required) | Subskrypcja App2 |
| `admin_password` | (required) | Hasło Panoramy i FW (min 12 znaków) |
| `panorama_vm_auth_key` | `""` | Device Registration Key (wygeneruj po KROK 2) |
| `fw_auth_code` | `""` | Auth code VM-Series BYOL z CSP Portal |
| `terraform_operator_ips` | `[]` | Twoje publiczne IP (dla Bootstrap SA access) |

### Phase 2 – phase2-panorama-config/terraform.tfvars

| Zmienna | Opis |
|---------|------|
| `panorama_password` | Hasło Panoramy (to samo co `admin_password` w Phase 1) |
| `panorama_serial_number` | Serial Number Panoramy z CSP Portal (format: `007300XXXXXXX`) |
| `external_lb_public_ip` | Publiczny IP External LB (`terraform output external_lb_public_ip`) |

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
│   ├── bootstrap/                  # Bootstrap SA dla VM-Series FW (nie dla Panoramy)
│   │   ├── main.tf                 # SA, kontenery, blobs FW1/FW2
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── templates/
│   │       └── init-cfg.txt.tpl    # FW bootstrap config (vm-auth-key opcjonalny)
│   ├── panorama/                   # Panorama VM (Management VNet, bez bootstrap)
│   │   ├── main.tf                 # VM, NIC, disk – brak custom_data
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── panorama_config/            # Panorama konfiguracja przez panos provider
│   │   ├── main.tf                 # Template Stack, DG, policies
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── firewall/                   # VM-Series FW HA pair
│   │   ├── main.tf                 # 2x VMs, 4x NICs each, Availability Set
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── loadbalancer/               # External LB + Internal LB
│   ├── routing/                    # UDR Route Tables (App1, App2)
│   ├── frontdoor/                  # Azure Front Door Premium
│   ├── spoke1_app/                 # App1 – Ubuntu + Apache Hello World
│   └── spoke2_dc/                  # App2 – Windows Server 2022 DC
│
├── phase2-panorama-config/         # ODRĘBNY workspace Terraform – konfiguracja Panoramy
│   ├── main.tf                     # XML API: hostname, serial, licencja + panos provider
│   ├── variables.tf
│   ├── providers.tf
│   ├── outputs.tf
│   └── terraform.tfvars.example
│
├── optional/
│   └── dc-promote/                 # Opcjonalna ręczna promocja DC (DSC)
│
└── scripts/
    ├── generate-vm-auth-key.sh     # Automatyczne generowanie vm-auth-key z Panoramy API
    ├── check-panorama.sh           # Dostęp przez Bastion (SSH, tunnel, RDP)
    └── fix-drift.sh                # Naprawa driftu konfiguracji
```

---

## Ważne uwagi techniczne

### Panorama – brak bootstrap, konfiguracja przez Phase 2

Panorama BYOL na Azure **nie korzysta z customData/bootstrap**. Cały proces konfiguracji odbywa się przez Phase 2 (XML API + panos Terraform provider):

| Krok | Mechanizm | Co robi |
|------|-----------|---------|
| Phase 1a | Terraform (azurerm) | Tworzy VM Panoramy – startuje z domyślnym hostname |
| Phase 2 – Step 1 | `curl` XML API | Czeka aż Panorama odpowie (max 20 min) |
| Phase 2 – Step 2 | `curl` XML API | Ustawia hostname + commit |
| Phase 2 – Step 3 | `curl` XML API | Ustawia serial number + commit + `request license fetch` |
| Phase 2 – Step 4 | panos provider | Template Stack, Device Group, interfaces, zones, routes, policies |
| Phase 2 – Step 5 | `curl` XML API | Commit końcowy |

### Aktywacja licencji Panoramy BYOL

**Wymagana kolejność:**
1. CSP Portal: zarejestruj auth-code → otrzymaj **Serial Number** (`007300XXXXXXX`)
2. Phase 2 ustawia serial number w Panoramie (XML API config)
3. Phase 2 wykonuje `commit`
4. Phase 2 wywołuje `request license fetch` (BEZ auth-code)
5. Panorama łączy się z serwerem PANW i pobiera licencję

> ⚠️ Komenda `request license fetch auth-code XXXX` **nie działa** dla Panoramy BYOL na Azure. Auth-code musi być najpierw powiązany z serial number na CSP Portal.

### vm-auth-key (Device Registration Auth Key)

- **Wymagany** dla automatycznej rejestracji FW w Panoramie przy starcie
- Generuj w Panoramie **po** aktywacji licencji (Phase 2)
- Wbudowany w FW init-cfg (`vm-auth-key=`)
- Ważny 168h (7 dni) domyślnie – ustaw przed wdrożeniem FW
- Tryb operacyjny Panoramy: `admin@panorama> request vm-auth-key generate lifetime 168`

### PAN-OS CLI – tryby pracy

| Tryb | Prompt | Komendy |
|------|--------|---------|
| Operacyjny | `admin@panorama>` | `show`, `request`, `debug` |
| Konfiguracyjny | `admin@panorama#` | `set`, `delete`, `commit` |

```bash
# Wejście w tryb konfiguracyjny
admin@panorama> configure

# Powrót do operacyjnego
admin@panorama# exit

# Sprawdzenie licencji (tryb operacyjny)
admin@panorama> show license

# Sprawdzenie info systemowego
admin@panorama> show system info
```

### NSG reguły

- **snet-mgmt (Transit)**: SSH/HTTPS tylko z Management VNet (10.255.0.0/16)
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

### Panorama nie odpowiada po ~20 min

```bash
# Sprawdź status VM
az vm show --show-details \
  -g rg-transit-hub -n vm-panorama \
  --query "{state:powerState, ip:privateIps}" -o table

# Sprawdź czy Bastion tunnel działa
curl -sk --max-time 10 -o /dev/null -w "%{http_code}" https://127.0.0.1:44300/php/login.php
# Oczekiwany wynik: 200 lub 302

# Sprawdź logi Panoramy przez SSH
PANORAMA_ID=$(terraform output -raw panorama_vm_id)
az network bastion ssh \
  --name bastion-management \
  --resource-group rg-transit-hub \
  --target-resource-id "$PANORAMA_ID" \
  --auth-type password --username panadmin

admin@panorama> show system info
```

### Phase 2 – błąd aktywacji licencji

```bash
# Sprawdź czy serial number jest poprawny
admin@panorama> show system info | match serial

# Sprawdź dostęp do internetu (NAT Gateway w Management VNet)
admin@panorama> ping host 8.8.8.8 source 10.255.0.4

# Sprawdź status licencji
admin@panorama> show license

# Jeśli serial number nie zgadza się z CSP – ustaw ręcznie (tryb konfiguracyjny)
admin@panorama> configure
admin@panorama# set deviceconfig system serial 007300XXXXXXX
admin@panorama# commit
admin@panorama# exit

# Pobierz licencję ręcznie (tryb operacyjny)
admin@panorama> request license fetch
```

### FW nie rejestruje się w Panoramie

```bash
# SSH do FW przez Bastion (resource ID)
FW1_ID=$(terraform output -raw fw1_vm_id)
az network bastion ssh \
  --name bastion-management \
  --resource-group rg-transit-hub \
  --target-resource-id "$FW1_ID" \
  --auth-type password --username panadmin

# Sprawdź status Panoramy z FW
admin@fw1> show panorama-status

# Sprawdź bootstrap log
admin@fw1> debug bootstrap detail

# Ustaw Panoramę ręcznie jeśli init-cfg nie zadziałał
admin@fw1> configure
admin@fw1# set deviceconfig system panorama-server 10.255.0.4
admin@fw1# commit
admin@fw1# exit
```

### vm-auth-key expired

```bash
# Wygeneruj nowy klucz przez SSH do Panoramy
PANORAMA_ID=$(terraform output -raw panorama_vm_id)
az network bastion ssh \
  --name bastion-management \
  --resource-group rg-transit-hub \
  --target-resource-id "$PANORAMA_ID" \
  --auth-type password --username panadmin

admin@panorama> request vm-auth-key generate lifetime 168

# Lub przez skrypt (wymaga Bastion tunnel na port 44300)
./scripts/check-panorama.sh --tunnel   # Terminal 1
PANORAMA_IP=127.0.0.1 PANORAMA_PORT=44300 ./scripts/generate-vm-auth-key.sh  # Terminal 2

# Zaktualizuj terraform.tfvars i odśwież bootstrap SA
# panorama_vm_auth_key = "2:NOWY_KLUCZ"
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
