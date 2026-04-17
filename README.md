# 🔥 Azure Transit VNet – Palo Alto VM-Series HA

> **Kompletna infrastruktura jako kod (IaaC) dla referencyjnej architektury Palo Alto Networks na Azure**

[![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.5-7B42BC?logo=terraform)](https://www.terraform.io/)
[![PAN-OS](https://img.shields.io/badge/PAN--OS-latest%20BYOL-E31837?logo=paloaltonetworks)](https://www.paloaltonetworks.com/)
[![Azure](https://img.shields.io/badge/Azure-West%20Europe-0078D4?logo=microsoftazure)](https://azure.microsoft.com/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Terraform Validate](https://img.shields.io/badge/terraform%20validate-passing-brightgreen)](.)

Implementacja referencyjna oparta na: **[PAN Azure Transit VNet Deployment Guide](https://www.paloaltonetworks.com/apps/pan/public/downloadResource?pagePath=/content/pan/en_US/resources/guides/azure-transit-vnet-deployment-guide)**

---

## 📋 Spis treści

1. [Architektura](#-architektura)
2. [Model dostępu do zarządzania (Zero-Trust)](#-model-dostępu-do-zarządzania-zero-trust)
3. [Wymagania wstępne](#-wymagania-wstępne)
4. [Konfiguracja zmiennych](#-konfiguracja-zmiennych)
5. [Phase 1a – Sieć + Panorama](#-phase-1a--sieć--panorama)
6. [Phase 1b – Bootstrap + Firewalle + Spokes](#-phase-1b--bootstrap--firewalle--spokes)
7. [Phase 2 – Konfiguracja Panoramy](#-phase-2--konfiguracja-panoramy)
8. [Dostęp przez Azure Bastion (SSH + Port Forward)](#-dostęp-przez-azure-bastion-ssh--port-forward)
9. [Weryfikacja po wdrożeniu](#-weryfikacja-po-wdrożeniu)
10. [Rozwiązywanie problemów](#-rozwiązywanie-problemów)
11. [Bezpieczeństwo](#-bezpieczeństwo)
12. [Zasoby Azure](#-zasoby-azure)
13. [🚨 Destroy – jak usunąć infrastrukturę](#-destroy--jak-usunąć-infrastrukturę)

---

## 🏗 Architektura

```
                          ┌──────────────────────────────────────────────────────────────┐
  Internet                │           Azure Transit VNet (Hub)  10.0.0.0/16              │
      │                   │                                                                │
      ▼                   │  ┌──── snet-mgmt  10.0.0.0/24 (NO PUBLIC IPs!) ──────────┐  │
 ┌─────────────┐          │  │  vm-panorama          10.0.0.10  ←─ PRIVATE ONLY       │  │
 │ Azure Front │          │  │  vm-panos-fw1 (eth0)  10.0.0.4   ←─ PRIVATE ONLY       │  │
 │ Door Premium│          │  │  vm-panos-fw2 (eth0)  10.0.0.5   ←─ PRIVATE ONLY       │  │
 │ (global     │          │  │  NAT Gateway → pip-nat-gateway-mgmt (outbound only)     │  │
 │  anycast)   │          │  └────────────────────────────────────────────────────────┘  │
 └──────┬──────┘          │                  ↑ dostęp admin TYLKO przez:                 │
        │                  │  ┌──── AzureBastionSubnet  10.0.4.0/26 ───────────────────┐ │
        ▼                  │  │  bastion-hub (Standard SKU, tunneling_enabled=true)     │ │
 ┌─────────────┐          │  │  pip-bastion-hub ← jedyny publiczny IP do zarządzania  │ │
 │External LB  │ ◄────────┤  └───────────────────────────────────────────────────────┘ │
 │pip-ext-lb   │          │                                                               │
 └─────────────┘          │  ┌──── snet-untrust  10.0.1.0/24 ─────────────────────────┐ │
        │                  │  │  nic-fw1-untrust (10.0.1.4) → External LB backend      │ │
        │                  │  │  nic-fw2-untrust (10.0.1.5) → External LB backend      │ │
        │                  │  └────────────────────────────────────────────────────────┘ │
        │                  │  ┌──── snet-trust  10.0.2.0/24 ──────────────────────────┐  │
        │                  │  │  nic-fw1-trust (10.0.2.4) → Internal LB backend       │  │
        │                  │  │  nic-fw2-trust (10.0.2.5) → Internal LB backend       │  │
        │                  │  │  lb-internal-panos (10.0.2.100) ← UDR next-hop        │  │
        │                  │  └────────────────────────────────────────────────────────┘  │
        │                  │  ┌──── snet-ha  10.0.3.0/24 ──────────────────────────────┐ │
        │                  │  │  fw1-ha (10.0.3.4) ──HA2── fw2-ha (10.0.3.5)          │ │
        │                  │  └────────────────────────────────────────────────────────┘ │
        │                  └──────────────────────────────┬───────────────────────────────┘
        │                               VNet Peering (bidirectional)
        │                     ┌──────────────┴────────────────────┐
        │       ┌─────────────▼────────────┐      ┌──────────────▼──────────────┐
        │       │  Spoke1 VNet 10.1.0.0/16 │      │  Spoke2 VNet 10.2.0.0/16    │
        │       │  UDR: 0/0 → 10.0.2.100   │◄────►│  UDR: 0/0 → 10.0.2.100     │
        │       │  vm-spoke1-apache 10.1.0.4│      │  vm-spoke2-dc    10.2.0.4   │
        └──────►│  (Ubuntu, Apache2)        │      │  Azure Bastion Spoke2       │
         DNAT   └──────────────────────────┘      └──────────────────────────────┘
```

### Przepływy ruchu

| Typ ruchu | Ścieżka | Inspekcja FW |
|-----------|---------|:---:|
| **Inbound HTTP/HTTPS** | Client → AFD → External LB → VM-Series (DNAT) → Apache 10.1.0.4 | ✅ |
| **Outbound Internet** | App (Spoke) → UDR → Internal LB → VM-Series (SNAT) → Internet | ✅ |
| **East-West Spoke→Spoke** | Spoke1 → UDR → Internal LB → VM-Series → Spoke2 | ✅ |
| **FW → Panorama (mgmt)** | FW1/FW2 (10.0.0.4/5) → prywatnie → Panorama (10.0.0.10) | – |
| **Admin → FW/Panorama** | Admin → Hub Bastion (pip) → SSH/Tunnel → VM prywatne | – |
| **Admin → DC RDP** | Admin → Spoke2 Bastion → vm-spoke2-dc (bez publicznego IP na DC) | – |
| **Outbound mgmt** | Panorama/FW eth0 → NAT Gateway (pip-nat-gateway-mgmt) → Internet | – |

---

## 🔒 Model dostępu do zarządzania (Zero-Trust)

**Kluczowa zasada**: Żadna VM zarządzania (Panorama, FW1, FW2) **nie ma publicznego adresu IP**.

| Zasób | Publiczny IP? | Dostęp |
|-------|:---:|--------|
| vm-panorama (10.0.0.10) | ❌ | Hub Bastion → tunnel port 44300 → https://localhost:44300 |
| vm-panos-fw1 (10.0.0.4) | ❌ | Hub Bastion → SSH lub tunnel port 44301 → https://localhost:44301 |
| vm-panos-fw2 (10.0.0.5) | ❌ | Hub Bastion → SSH lub tunnel port 44302 → https://localhost:44302 |
| vm-spoke2-dc (10.2.0.4) | ❌ | Spoke2 Bastion → RDP przez Azure Portal |
| pip-bastion-hub | ✅ | Azure Bastion – jedyny punkt wejścia do zarządzania |
| pip-external-lb | ✅ | Ruch aplikacyjny (HTTP/HTTPS) przez FW |
| pip-nat-gateway-mgmt | ✅ | Wychodzący internet z snet-mgmt (licencje, updates) – tylko outbound |

### Komunikacja FW ↔ Panorama (prywatna)

```
FW1 (10.0.0.4) ─────────────────────────────→ Panorama (10.0.0.10)
FW2 (10.0.0.5) ─────────────────────────────→ Panorama (10.0.0.10)
  ↕ snet-mgmt (10.0.0.0/24)  HA1 heartbeat ↕
  Brak ruchu przez publiczne IP!
```

### Dostęp admina (przez Hub Azure Bastion)

```
Admin (laptop)
  └── https://portal.azure.com / az CLI
        └── pip-bastion-hub (publiczny IP Bastion)
              └── AzureBastionSubnet (10.0.4.0/26)
                    ├── SSH → vm-panos-fw1  (10.0.0.4)
                    ├── SSH → vm-panos-fw2  (10.0.0.5)
                    ├── SSH → vm-panorama   (10.0.0.10)
                    └── Tunnel → localhost:44300 → vm-panorama:443 (HTTPS GUI)
```

---

## ✅ Wymagania wstępne

| Narzędzie | Min. wersja |
|-----------|:-----------:|
| [Terraform](https://www.terraform.io/downloads) | 1.5.0 |
| [Azure CLI](https://docs.microsoft.com/cli/azure/install-azure-cli) | 2.60.0 |
| [Azure Bastion extension for CLI](https://learn.microsoft.com/cli/azure/network/bastion) | – |

```bash
# Zainstaluj rozszerzenie Azure Bastion dla CLI (jednorazowo)
az extension add --name bastion

# Zaloguj się
az login
az account set --subscription "<hub_subscription_id>"
```

**Uprawnienia Azure**: `Owner` lub `Contributor + User Access Administrator` na wszystkich subskrypcjach.

**Licencje BYOL** (z [Palo Alto CSP Portal](https://support.paloaltonetworks.com/)):
- 2x auth code VM-Series BYOL → `fw_auth_code`
- 1x auth code Panorama BYOL → `panorama_auth_code`

---

## ⚙️ Konfiguracja zmiennych

```bash
cp terraform.tfvars.example terraform.tfvars
```

```hcl
# ═══════════════════════════ WYMAGANE ═══════════════════════════
hub_subscription_id    = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
spoke1_subscription_id = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
spoke2_subscription_id = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

admin_username    = "panadmin"
admin_password    = "Str0ng!Password2024"   # min 12 znaków

dc_admin_username = "dcadmin"
dc_admin_password = "DC-Str0ng!2024"

fw_auth_code       = "I1234567-XXXX-XXXX-XXXX"
panorama_auth_code = "P7654321-XXXX-XXXX-XXXX"

# Twój publiczny IP (dla Storage Account network_rules):
terraform_operator_ips = ["X.X.X.X"]   # curl -s https://api.ipify.org

# ═══════════════════════ PO PHASE 1a ════════════════════════════
# Wygeneruj w Panoramie przez Bastion Tunnel, potem uzupełnij:
panorama_vm_auth_key = ""   # → uzupełnij po Phase 1a

# ═══════════════════════ OPCJONALNE ═════════════════════════════
location             = "West Europe"
fw_vm_size           = "Standard_D8s_v3"
pan_os_version       = "latest"
dc_skip_auto_promote = false
```

---

## 🚀 Phase 1a – Sieć + Panorama

> **CEL**: Uruchomić Hub VNet, Bastion, Panoramę. Potem przez Bastion wygenerować `vm-auth-key`.

### Krok 1 – Inicjalizacja i walidacja

```bash
cd /Users/mzalewski/TF/azure_ha_project
terraform init
terraform validate && echo "✓ validate OK"
```

### Krok 2 – Deploy Panoramy, sieci i Bastion huba

```bash
terraform apply \
  -target=azurerm_resource_group.hub \
  -target=azurerm_resource_group.spoke1 \
  -target=azurerm_resource_group.spoke2 \
  -target=module.networking \
  -target=module.panorama
```

> ⏱ ~8-12 minut. Tworzy ~40 zasobów (VNety, subnety, NSG, NAT GW, Hub Bastion, Panorama VM).

### Krok 3 – Poczekaj na Panoramę i otwórz tunel HTTPS

> ℹ️  `scripts/check-panorama.sh` służy do dostępu przez DC (Phase 1b+).
> W Phase 1a DC jeszcze nie istnieje – używamy bezpośredniego tunelu `--target-resource-id`.

**Ręcznie** (2 terminale):

```bash
# Terminal 1 – sprawdź status Panoramy
az vm get-instance-view -g rg-transit-hub -n vm-panorama \
  --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus" -o tsv
# Czekaj na: "VM running"

# Terminal 1 – otwórz tunel HTTPS do Panoramy (POZOSTAW OTWARTY)
# ⚠️  Używamy --target-resource-id (IpConnect nie pozwala na port 443 przez --target-ip-address)
PANORAMA_ID=$(terraform output -raw panorama_vm_id)
az network bastion tunnel \
  --name bastion-hub \
  --resource-group rg-transit-hub \
  --target-resource-id "$PANORAMA_ID" \
  --resource-port 443 \
  --port 44300
```

### Krok 4 – Zaloguj się do Panoramy przez tunel

```
Przeglądarka → https://localhost:44300
  ⚠️  Zaakceptuj certyfikat self-signed (ADVANCED → Proceed)
  Login: panadmin | Hasło: z terraform.tfvars
```

1. **Aktywuj licencję** (jeśli init-cfg nie aktywowało automatycznie):
   `Panorama → Licenses → Activate feature using auth code`

2. **Wygeneruj VM Auth Key**:
   `Panorama → Device Registration Auth Key → Generate`
   Ważność: **8760 hours** → Skopiuj klucz

### Krok 5 – Zaktualizuj `terraform.tfvars`

```hcl
panorama_vm_auth_key = "SKOPIOWANY-KLUCZ"
```

---

## 🚀 Phase 1b – Bootstrap + Firewalle + Spokes

> **CEL**: Wdrożyć resztę infrastruktury – FW startują z `vm-auth-key` w bootstrap i auto-rejestrują się w Panoramie.

### Krok 1 – Wdróż bootstrap (init-cfg z vm-auth-key)

```bash
terraform apply -target=module.bootstrap
```

### Krok 2 – Wdróż całą pozostałą infrastrukturę

```bash
terraform apply \
  -target=module.loadbalancer \
  -target=module.firewall \
  -target=module.routing \
  -target=module.frontdoor \
  -target=module.spoke1_app \
  -target=module.spoke2_dc
```

> ⏱ ~20-30 minut (Bastion Spoke2 + Windows DC najwolniejsze)

### Krok 3 – Sprawdź outputs

```bash
terraform output
```

```
hub_bastion_name       = "bastion-hub"
hub_bastion_public_ip  = "X.X.X.X"      ← jedyny publiczny IP do zarządzania
nat_gateway_public_ip  = "Y.Y.Y.Y"      ← outbound snet-mgmt (licencje, updates)
external_lb_public_ip  = "Z.Z.Z.Z"      ← ruch aplikacyjny
fw1_mgmt_private_ip    = "10.0.0.4"
fw2_mgmt_private_ip    = "10.0.0.5"
panorama_private_ip    = "10.0.0.10"
frontdoor_endpoint_hostname = "endpoint-xxx.z01.azurefd.net"
```

### Krok 4 – Zweryfikuj rejestrację FW w Panoramie

```bash
# Otwórz tunnel do Panoramy (Terminal 1)
# Lub przez DC: ./scripts/check-panorama.sh → RDP → https://10.0.0.10
PANORAMA_ID=$(terraform output -raw panorama_vm_id)
az network bastion tunnel \
  --name bastion-hub \
  --resource-group rg-transit-hub \
  --target-resource-id "$PANORAMA_ID" \
  --resource-port 443 \
  --port 44300
```

```
# W przeglądarce: https://localhost:44300
Panorama → Managed Devices → Summary
FW1 i FW2: Connected ✅
```

---

## 🔧 Phase 2 – Konfiguracja Panoramy

> **WYMÓG**: Aktywny Bastion Tunnel do Panoramy (Terminal 1) w czasie `terraform apply`!

### Krok 1 – Terminal 1: uruchom Bastion Tunnel (pozostaw otwarty)

```bash
# ⚠️  --target-resource-id wymagane dla portu 443 (IpConnect dozwala tylko 22 i 3389)
PANORAMA_ID=$(cd .. && terraform output -raw panorama_vm_id)
az network bastion tunnel \
  --name bastion-hub \
  --resource-group rg-transit-hub \
  --target-resource-id "$PANORAMA_ID" \
  --resource-port 443 \
  --port 44300
```

### Krok 2 – Terminal 2: przygotuj i uruchom Phase 2

```bash
cd phase2-panorama-config
cp terraform.tfvars.example terraform.tfvars
```

```hcl
# phase2-panorama-config/terraform.tfvars
panorama_hostname = "127.0.0.1"   # ← przez Bastion Tunnel (localhost)
panorama_port     = 44300          # ← port tunelu (match --port powyżej)
panorama_username = "panadmin"
panorama_password = "hasło z terraform.tfvars Phase 1"

external_lb_public_ip = "Z.Z.Z.Z"  # z terraform output (Phase 1)
```

```bash
terraform init
terraform apply
```

Terraform skonfiguruje Panoramę:
- ✅ Template + Template Stack
- ✅ Device Group
- ✅ Interfejsy (ethernet1/1, 1/2, 1/3)
- ✅ Strefy (untrust, trust)
- ✅ Virtual Router + trasy statyczne
- ✅ NAT rules: DNAT HTTP/HTTPS → Apache 10.1.0.4, SNAT outbound
- ✅ Security Policy

### Krok 3 – Commit & Push w Panoramie

```
Panorama GUI → Commit → Commit and Push → Template Stack + Device Group → Push Now
Czekaj na Push Success na FW1 i FW2
```

---

## 🔐 Dostęp przez Azure Bastion (SSH + GUI przez DC)

### Ograniczenie Azure Bastion IpConnect

Azure Bastion ma dwa tryby natywnego klienta:

| Tryb | Flaga | Dozwolone porty |
|------|-------|-----------------|
| **IpConnect** (`ip_connect_enabled=true`) | `--target-ip-address` | **tylko 22 i 3389** |
| **Tunneling** (`tunneling_enabled=true`) | `--target-resource-id` | **dowolny port** |

**GUI Panoramy/FW (port 443)** nie może być tunelowane przez `--target-ip-address`.
Zamiast tego używamy **DC (Windows Server) jako jump host** z przeglądarką.

---

### SSH do firewalli i Panoramy (PAN-OS CLI)

Porty 22 przez IpConnect – działają bezpośrednio przez `--target-ip-address`.

```bash
# SSH do FW1 (Active)
az network bastion ssh --name bastion-hub --resource-group rg-transit-hub \
  --target-ip-address 10.0.0.4 --auth-type password --username panadmin

# SSH do FW2 (Passive)
az network bastion ssh --name bastion-hub --resource-group rg-transit-hub \
  --target-ip-address 10.0.0.5 --auth-type password --username panadmin

# SSH do Panoramy
az network bastion ssh --name bastion-hub --resource-group rg-transit-hub \
  --target-ip-address 10.0.0.10 --auth-type password --username panadmin
```

---

### GUI Panoramy i FW – przez DC jako jump host

**DC (vm-spoke2-dc, 10.2.0.4)** ma dostęp do sieci Hub przez VNet peering.
Otwieramy RDP tunnel do DC, a z przeglądarki na DC wchodzimy na GUI Panoramy/FW.

#### Krok 1 – RDP tunnel (Terminal 1, blokuje)

```bash
# Skrypt automatyczny (zalecany):
./scripts/check-panorama.sh

# Lub ręcznie:
az network bastion tunnel --name bastion-hub --resource-group rg-transit-hub \
  --target-ip-address 10.2.0.4 \
  --resource-port 3389 \
  --port 33389
```

#### Krok 2 – Połącz się przez RDP (Terminal 2)

```bash
# Windows:
mstsc /v:localhost:33389

# macOS (Microsoft Remote Desktop):
# → Add PC → localhost:33389
```

Login: `dcadmin` | Hasło: `dc_admin_password` z `terraform.tfvars`

#### Krok 3 – GUI z przeglądarki na DC

| URL na DC | Cel | Uwagi |
|-----------|-----|-------|
| `https://10.0.0.10` | Panorama GUI | self-signed cert |
| `https://10.0.0.4` | FW1 GUI (Active) | self-signed cert |
| `https://10.0.0.5` | FW2 GUI (Passive) | self-signed cert |

> **⚠️ Certyfikat self-signed**: kliknij **Advanced → Proceed to 10.0.0.x (unsafe)**.

---

### Phase 2 – Tunel do Panoramy port 443 (panos provider)

Phase 2 Terraform wymaga połączenia HTTP do Panoramy na porcie 443.
Użyj `--target-resource-id` (tunneling, nie IpConnect → dowolny port):

```bash
# Terminal 1 – uruchom tunel (POZOSTAW OTWARTY):
PANORAMA_ID=$(terraform output -raw panorama_vm_id)
az network bastion tunnel --name bastion-hub --resource-group rg-transit-hub \
  --target-resource-id "$PANORAMA_ID" \
  --resource-port 443 \
  --port 44300
```

```bash
# Terminal 2 – uruchom Phase 2:
cd phase2-panorama-config
# panorama_hostname = "127.0.0.1", panorama_port = 44300
terraform apply
```

---

## 🔍 Weryfikacja po wdrożeniu

### Test 1 – Hello World via Azure Front Door

```bash
AFD=$(terraform output -raw frontdoor_endpoint_hostname)
curl -s "https://$AFD" | grep "HELLO WORLD" && echo "✅ AFD OK"
```

### Test 2 – External LB bezpośrednio

```bash
ELB=$(terraform output -raw external_lb_public_ip)
curl -s --connect-timeout 10 "http://$ELB" | grep "HELLO WORLD" && echo "✅ Ext LB OK"
```

### Test 3 – Panorama zarządzanie FW

```
Tunel: az network bastion tunnel ... --port 44300
GUI: https://localhost:44300
Panorama → Managed Devices → FW1 + FW2: Connected ✅, In Sync ✅
```

### Test 4 – East-West przez Monitor

```bash
# SSH do FW1 przez Bastion, wykonaj ping test
az network bastion ssh --name bastion-hub --resource-group rg-transit-hub \
  --target-ip-address 10.0.0.4 --auth-type password --username panadmin
# W PAN-OS CLI:
# > ping host 10.2.0.4 source 10.0.2.4
```

### Test 5 – DC przez Spoke2 Bastion

```bash
# Azure Portal → vm-spoke2-dc → Connect → Bastion
# PowerShell: Get-ADDomain | Select Name, DomainMode
# Oczekiwany wynik: panw.labs
```

---

## 🔧 Rozwiązywanie problemów

### Problem 1: Storage Account 403

```bash
curl -s https://api.ipify.org  # sprawdź aktualny IP
# Dodaj do terraform.tfvars:
# terraform_operator_ips = ["NOWY.IP"]
terraform apply -target=module.bootstrap
```

### Problem 2: ImageVersionDeprecated

```hcl
pan_os_version = "latest"  # domyślne w tym projekcie
```

### Problem 3: State drift – "already exists"

```bash
chmod +x scripts/fix-drift.sh && ./scripts/fix-drift.sh
terraform apply
```

### Problem 4: DC extension timeout

```hcl
dc_skip_auto_promote = true  # jeśli extension już uruchomione w tle
```

### Problem 5: FW nie rejestruje się w Panoramie

1. Sprawdź czy `panorama_vm_auth_key` nie jest pusty w tfvars
2. Zrestartuj FW po aktualizacji bootstrap:
   ```bash
   az vm restart -g rg-transit-hub -n vm-panos-fw1
   az vm restart -g rg-transit-hub -n vm-panos-fw2
   ```
3. Sprawdź w Panoramie: `Monitor → System` – logi rejestracji

### Problem 6: Bastion Tunnel – "Tunnel is not available"

```bash
# Sprawdź czy Bastion Standard jest wdrożony
az network bastion show -g rg-transit-hub -n bastion-hub --query "sku.name" -o tsv
# Musi zwrócić: "Standard"

# Sprawdź rozszerzenie CLI
az extension list --query "[?name=='bastion'].version" -o tsv
az extension update --name bastion
```

### Problem 7: Phase 2 – "connection refused 127.0.0.1:44300"

```
Tunel Bastion MUSI być aktywny w osobnym terminalu przed terraform apply Phase 2!
Sprawdź czy terminal z az network bastion tunnel nadal działa.
```

---

## 🔐 Bezpieczeństwo

### Architektura Zero-Trust (wbudowana)

- ✅ **Brak publicznych IP** na VM zarządzania (Panorama, FW1, FW2)
- ✅ **Hub Azure Bastion Standard** – jedyny punkt wejścia do zarządzania
- ✅ **NAT Gateway** – kontrolowany ruch wychodzący z snet-mgmt
- ✅ **NSG snet-mgmt** – SSH/HTTPS tylko z `10.0.4.0/26` (Bastion subnet)
- ✅ **FW↔Panorama** – komunikacja tylko prywatną siecią (10.0.0.x)
- ✅ **Storage Account** – `network_rules default_action=Deny`, dostęp przez Service Endpoint

### Dodatkowe zalecenia produkcyjne

1. **Remote State** w Azure Storage Account:
   ```hcl
   backend "azurerm" {
     resource_group_name  = "rg-terraform-state"
     storage_account_name = "stterraformstate"
     container_name       = "tfstate"
     key                  = "transit-vnet-ha.tfstate"
   }
   ```

2. **Hasła i auth codes** przez zmienne środowiskowe:
   ```bash
   export TF_VAR_admin_password="YourPassword"
   export TF_VAR_fw_auth_code="xxxx"
   export TF_VAR_panorama_auth_code="yyyy"
   ```

3. **`terraform.tfvars`** jest w `.gitignore` – nigdy nie usuwaj tego wpisu.

4. **Panorama i FW access** – ograniczone do Hub Bastion. Jeśli potrzeba dodatkowego dostępu z VPN, dodaj odpowiednie reguły NSG na `snet-mgmt`.

---

## 🗂 Zasoby Azure (~70 obiektów)

<details>
<summary><b>Kliknij, aby rozwinąć pełną listę zasobów</b></summary>

| Moduł | Zasób | Ilość |
|-------|-------|:-----:|
| networking | VNet (hub + 2x spoke) | 3 |
| networking | Subnet (mgmt, untrust, trust, ha, hub-bastion, spoke1-wl, spoke2-wl, spoke2-bastion) | 8 |
| networking | NSG (mgmt, untrust, trust, ha, hub-bastion, spoke1-wl, spoke2-bastion, spoke2-wl) | 8 |
| networking | NSG Association | 8 |
| networking | VNet Peering (hub↔spoke1 x2, hub↔spoke2 x2) | 4 |
| networking | Public IP: pip-external-lb, pip-bastion-hub, pip-nat-gateway-mgmt | 3 |
| networking | NAT Gateway: natgw-mgmt | 1 |
| networking | Azure Bastion: bastion-hub (Standard, tunneling=true) | 1 |
| panorama | nic-panorama-mgmt (private only) | 1 |
| panorama | vm-panorama (Standard_D4s_v3) | 1 |
| panorama | disk-panorama-logs (2 TB) | 1 |
| panorama | null_resource: accept_panorama_terms | 1 |
| bootstrap | Storage Account (network_rules=Deny) | 1 |
| bootstrap | bootstrap container + 8 blobs (fw1 + fw2) | 9 |
| bootstrap | User Assigned Managed Identity | 1 |
| bootstrap | Role Assignment (Storage Blob Data Reader) | 1 |
| firewall | null_resource: accept_panos_terms | 1 |
| firewall | Availability Set | 1 |
| firewall | NICs: 4x FW1 + 4x FW2 (private only) | 8 |
| firewall | VM: vm-panos-fw1, vm-panos-fw2 (D8s_v3) | 2 |
| firewall | LB backend associations: 4x | 4 |
| loadbalancer | External LB (public, TCP 80+443) | 1 |
| loadbalancer | Internal LB (private, HA Ports) | 1 |
| loadbalancer | Backend pools, probes, rules, outbound rule | 7 |
| frontdoor | AFD Premium, Endpoint, Origin Group, Origin, Route | 5 |
| routing | Route Tables (spoke1 + spoke2) | 2 |
| routing | Routes (4 trasy) + Associations | 6 |
| spoke1_app | nic + vm-spoke1-apache (Ubuntu 22.04) | 2 |
| spoke2_dc | nic + vm-spoke2-dc (WS 2022) | 2 |
| spoke2_dc | vm extension: promote-to-dc (AD DS) | 0-1 |
| spoke2_dc | Public IP Bastion Spoke2 + Bastion Host | 2 |

</details>

---

## 📁 Struktura plików

```
azure-transit-vnet-ha/
├── providers.tf                    # Terraform + azurerm (hub/spoke1/spoke2)
├── variables.tf                    # Globalne zmienne
├── main.tf                         # Root module
├── outputs.tf                      # Wyjścia (prywatne IPs, bastion info)
├── terraform.tfvars                # ⚠️ NIE commituj do git
├── terraform.tfvars.example        # Szablon
├── .gitignore
├── README.md
├── scripts/
│   ├── check-panorama.sh           # Czeka na Panoramę + otwiera Bastion Tunnel
│   └── fix-drift.sh                # Naprawa state drift
├── modules/
│   ├── networking/                 # Hub VNet, Bastion, NAT GW, Spokes, NSG
│   ├── panorama/                   # VM Panorama (private only, NAT GW outbound)
│   ├── bootstrap/                  # Storage Account + blobs + Managed Identity
│   ├── firewall/                   # 2x VM-Series HA (private only)
│   ├── loadbalancer/               # External LB (TCP 80/443) + Internal LB (HA)
│   ├── frontdoor/                  # Azure Front Door Premium
│   ├── routing/                    # UDR Spoke1 + Spoke2
│   ├── spoke1_app/                 # Ubuntu + Apache2
│   ├── spoke2_dc/                  # Windows DC + Spoke2 Bastion
│   └── panorama_config/            # panos provider resources
└── phase2-panorama-config/         # OSOBNY katalog Phase 2
    ├── providers.tf                # panos provider (przez Bastion tunnel)
    ├── variables.tf                # panorama_hostname=127.0.0.1, port=44300
    ├── main.tf
    ├── outputs.tf
    └── terraform.tfvars.example
```

---

## 📚 Źródła

- [Palo Alto Networks: Azure Transit VNet Deployment Guide](https://www.paloaltonetworks.com/apps/pan/public/downloadResource?pagePath=/content/pan/en_US/resources/guides/azure-transit-vnet-deployment-guide)
- [VM-Series Bootstrap on Azure](https://docs.paloaltonetworks.com/vm-series/11-1/vm-series-deployment/bootstrap-the-vm-series-firewall/bootstrap-the-vm-series-firewall-in-azure)
- [Azure Bastion – Native Client Support](https://learn.microsoft.com/azure/bastion/native-client)
- [az network bastion tunnel](https://learn.microsoft.com/cli/azure/network/bastion#az-network-bastion-tunnel)
- [Azure Standard Load Balancer](https://docs.microsoft.com/azure/load-balancer/)
- [Terraform panos Provider](https://registry.terraform.io/providers/PaloAltoNetworks/panos/latest/docs)

---

## 🚨 Destroy – jak usunąć infrastrukturę

### Opcja A – przez Terraform

```bash
cd /Users/mzalewski/TF/azure_ha_project
terraform destroy -auto-approve 2>&1 | tee destroy.log
tail -f destroy.log | grep -E "(Destroying|Destroyed|Error)"
```

### Opcja B – przez Azure CLI (gdy state uszkodzony)

```bash
az group delete --name rg-transit-hub  --yes --no-wait
az group delete --name rg-spoke1-app   --yes --no-wait
az group delete --name rg-spoke2-dc    --yes --no-wait

# Sprawdzaj status
az group list --query "[?name=='rg-transit-hub'||name=='rg-spoke1-app'||name=='rg-spoke2-dc'].{Name:name,State:properties.provisioningState}" -o table
```

### Po destroy – reset state

```bash
# Gdy resource groups zniknęły ale state nie jest pusty
terraform state list | xargs -I {} terraform state rm {}
terraform init -reconfigure
```

---

## 📄 Licencja

MIT. Szczegóły: [LICENSE](LICENSE).

---

*Azure Transit VNet – VM-Series Active/Passive HA Reference Architecture*
*Zero-Trust Management via Azure Bastion | Palo Alto Networks | Terraform | Azure*
