# 🔥 Azure Transit VNet – Palo Alto VM-Series HA

> **Kompletna infrastruktura jako kod (IaaC) dla referencyjnej architektury Palo Alto Networks na Azure**

[![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.5-7B42BC?logo=terraform)](https://www.terraform.io/)
[![PAN-OS](https://img.shields.io/badge/PAN--OS-11.1%20BYOL-E31837?logo=paloaltonetworks)](https://www.paloaltonetworks.com/)
[![Azure](https://img.shields.io/badge/Azure-West%20Europe-0078D4?logo=microsoftazure)](https://azure.microsoft.com/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Terraform Validate](https://img.shields.io/badge/terraform%20validate-passing-brightgreen)](.)

Implementacja referencyjna oparta na: **[PAN Azure Transit VNet Deployment Guide](https://www.paloaltonetworks.com/apps/pan/public/downloadResource?pagePath=/content/pan/en_US/resources/guides/azure-transit-vnet-deployment-guide)**

---

## 📋 Spis treści

1. [Architektura](#-architektura)
2. [Komponenty projektu](#-komponenty-projektu)
3. [Struktura plików](#-struktura-plików)
4. [Zasoby Azure](#-zasoby-azure)
5. [Wymagania wstępne](#-wymagania-wstępne)
6. [Konfiguracja zmiennych](#-konfiguracja-zmiennych)
7. [Wdrożenie – Phase 1 (Infrastruktura)](#-wdrożenie--phase-1-infrastruktura)
8. [Wdrożenie – Phase 2 (Panorama Config)](#-wdrożenie--phase-2-panorama-config)
9. [Weryfikacja po wdrożeniu](#-weryfikacja-po-wdrożeniu)
10. [Outputs](#-outputs)
11. [Usunięcie infrastruktury](#-usunięcie-infrastruktury)
12. [Bezpieczeństwo](#-bezpieczeństwo)

---

## 🏗 Architektura

```
                          ┌─────────────────────────────────────────────────────────────┐
  Internet                │           Azure Transit VNet (Hub)  10.0.0.0/16             │
      │                   │                                                               │
      ▼                   │  ┌──────────── snet-mgmt  10.0.0.0/24 ─────────────────┐   │
 ┌─────────────┐          │  │  pip-panorama → vm-panorama (10.0.0.10)              │   │
 │ Azure Front │          │  │  pip-fw1-mgmt → vm-panos-fw1 (eth0, 10.0.0.4)       │   │
 │ Door Premium│          │  │  pip-fw2-mgmt → vm-panos-fw2 (eth0, 10.0.0.5)       │   │
 │ (global     │          │  └──────────────────────────────────────────────────────┘   │
 │  anycast)   │          │                                                               │
 └──────┬──────┘          │  ┌──────────── snet-untrust  10.0.1.0/24 ──────────────┐   │
        │ HTTP/HTTPS       │  │  nic-fw1-untrust (10.0.1.4) ─────────────┐          │   │
        ▼                  │  │  nic-fw2-untrust (10.0.1.5) ─────────────┤          │   │
 ┌─────────────┐          │  └──────────────────────────────────┬─────────┘          │   │
 │External LB  │ ◄────────┤                                     │                     │   │
 │pip-ext-lb   │          │  ┌──────────── snet-trust  10.0.2.0/24 ────────────────┐ │   │
 └─────────────┘          │  │  nic-fw1-trust (10.0.2.4) ──────┘                   │ │   │
        │                  │  │  nic-fw2-trust (10.0.2.5)                           │ │   │
        │                  │  │  lb-internal-panos (10.0.2.100) ← UDR next-hop     │ │   │
        │                  │  └────────────────────────────────────────────────────┘ │   │
        │   ┌──────────────┘                                                          │   │
        │   │              │  ┌──────────── snet-ha  10.0.3.0/24 ──────────────────┐ │   │
        │   │   HA pair:   │  │  nic-fw1-ha (10.0.3.4) ──HA2──nic-fw2-ha (10.0.3.5)│ │   │
        │   │  Active /    │  └──────────────────────────────────────────────────────┘ │   │
        │   │  Passive     └──────────────────────────────┬────────────────────────────┘   │
        │   │                                              │                                 │
        │   │                               VNet Peering (bidirectional)                    │
        │   │                     ┌──────────────┴──────────────────────┐                   │
        │   │                     │                                      │                   │
        │   │       ┌─────────────▼────────────┐         ┌──────────────▼──────────────┐   │
        │   │       │  Spoke1 VNet             │         │  Spoke2 VNet                 │   │
        │   │       │  10.1.0.0/16             │         │  10.2.0.0/16                 │   │
        │   │       │  snet-workload /24       │         │  snet-workload /24           │   │
        │   │       │  UDR: 0/0 → 10.0.2.100  │◄───────►│  UDR: 0/0 → 10.0.2.100     │   │
        │   │       │                          │         │  snet-bastion /27            │   │
        │   │       │  vm-spoke1-apache        │         │  vm-spoke2-dc (Windows 2022) │   │
        │   │       │  (Ubuntu, Apache2)       │         │  panw.labs AD Domain         │   │
        │   └──────►│  10.1.0.4               │         │  10.2.0.4                    │   │
        │    DNAT   └──────────────────────────┘         │  Azure Bastion (Standard)    │   │
        │            ↑ Hello World App                    └──────────────────────────────┘   │
        │             Traffic path:                                                           │
        └──────── AFD → External LB → VM-Series (inspect+DNAT) → Apache                     │
```

### Przepływy ruchu

| Typ ruchu | Ścieżka | Inspekcja FW |
|-----------|---------|:---:|
| **Inbound HTTP/HTTPS** | Client → AFD → External LB → VM-Series (DNAT) → Apache 10.1.0.4 | ✅ |
| **Outbound Internet** | App (Spoke) → UDR → Internal LB → VM-Series (SNAT) → Internet | ✅ |
| **East-West Spoke→Spoke** | Spoke1 → UDR → Internal LB → VM-Series → Internal LB → Spoke2 | ✅ |
| **Management** | Admin → pip-fw1/fw2-mgmt → PAN-OS GUI/SSH | – |
| **Panorama mgmt** | Admin → pip-panorama → Panorama GUI | – |
| **DC RDP** | Admin → Azure Portal Bastion → vm-spoke2-dc (bez publicznego IP) | – |

---

## 📦 Komponenty projektu

| Moduł | Opis | Kluczowe zasoby |
|-------|------|-----------------|
| **`networking`** | Sieć – Hub i oba Spoke VNety | 3x VNet, 7x Subnet, 4x NSG, 4x VNet Peering, 3x Public IP |
| **`bootstrap`** | Paczka bootstrap dla VM-Series | Storage Account, blobs (init-cfg, authcodes), User-Assigned Managed Identity |
| **`panorama`** | Serwer zarządzania Panorama | VM (Standard_D4s_v3), 2TB data disk, Public IP |
| **`firewall`** | Para HA VM-Series | 2x VM PAN-OS 11.1 (8 vCPU), Availability Set, 4 NIC/VM, bootstrap via MI |
| **`loadbalancer`** | Balansery ruchu | External Standard LB (public) + Internal Standard LB (private 10.0.2.100) |
| **`routing`** | Routing Spoke VNetów | 2x UDR Route Table (domyślna trasa + east-west → Internal LB) |
| **`frontdoor`** | Globalny wejście HTTP/HTTPS | Azure Front Door Premium, Endpoint, Origin Group, Route |
| **`spoke1_app`** | Aplikacja demonstracyjna | Ubuntu 22.04, Apache2 Hello World (cloud-init), IP 10.1.0.4 |
| **`spoke2_dc`** | Kontroler domeny | Windows Server 2022, AD DS (panw.labs), Azure Bastion Standard |
| **`panorama_config`** | Konfiguracja Panorama (Phase 2) | Template, Device Group, Strefy, VR, Static Routes, NAT, Security Policy |

---

## 📁 Struktura plików

```
azure-transit-vnet-ha/
├── providers.tf                    # Terraform + azurerm (hub/spoke1/spoke2) + panos provider
├── variables.tf                    # Globalne zmienne wejściowe
├── main.tf                         # Root module – wszystkie wywołania modułów
├── outputs.tf                      # Wyjścia (IPs, hostnames, itd.)
├── terraform.tfvars                # ⚠️ WYPEŁNIJ PRZED DEPLOY (NIE commituj do git!)
├── terraform.tfvars.example        # Szablon tfvars – bezpieczny do commitowania
├── .gitignore                      # Wyklucza terraform.tfvars, .terraform/, tfstate
├── README.md                       # Ten plik
└── modules/
    ├── networking/
    │   ├── main.tf                 # VNety, subnety, NSG, peering, Public IPs
    │   ├── variables.tf
    │   └── outputs.tf
    ├── bootstrap/
    │   ├── main.tf                 # Storage Account, Managed Identity, bootstrap blobs
    │   ├── variables.tf
    │   ├── outputs.tf
    │   └── templates/
    │       └── init-cfg.txt.tpl    # Szablon init-cfg.txt dla VM-Series
    ├── panorama/
    │   ├── main.tf                 # VM Panorama, 2TB disk, Public IP
    │   ├── variables.tf
    │   ├── outputs.tf
    │   └── templates/
    │       └── panorama-init-cfg.txt.tpl
    ├── firewall/
    │   ├── main.tf                 # 2x VM-Series HA, Availability Set, NICs, bootstrap
    │   ├── variables.tf
    │   └── outputs.tf
    ├── loadbalancer/
    │   ├── main.tf                 # External LB + Internal LB
    │   ├── variables.tf
    │   └── outputs.tf
    ├── frontdoor/
    │   ├── main.tf                 # Azure Front Door Premium
    │   ├── variables.tf
    │   └── outputs.tf
    ├── routing/
    │   ├── main.tf                 # UDR Route Tables dla Spoke1 i Spoke2
    │   ├── variables.tf
    │   └── outputs.tf
    ├── spoke1_app/
    │   ├── main.tf                 # Ubuntu VM + Apache2 Hello World (cloud-init)
    │   ├── variables.tf
    │   └── outputs.tf
    ├── spoke2_dc/
    │   ├── main.tf                 # Windows Server 2022 DC + Azure Bastion
    │   ├── variables.tf
    │   └── outputs.tf
    └── panorama_config/
        ├── main.tf                 # panos provider: Template, DG, Zones, VR, NAT, Security
        ├── variables.tf
        └── outputs.tf
```

---

## 🗂 Zasoby Azure

<details>
<summary><b>Kliknij, aby rozwinąć pełną listę zasobów (~60+ obiektów Azure)</b></summary>

| Moduł | Typ zasobu | Nazwa | Ilość |
|-------|-----------|-------|:-----:|
| networking | `azurerm_virtual_network` | vnet-transit-hub, vnet-spoke1, vnet-spoke2 | 3 |
| networking | `azurerm_subnet` | snet-mgmt, snet-untrust, snet-trust, snet-ha, snet-spoke1-wl, snet-spoke2-wl, AzureBastionSubnet | 7 |
| networking | `azurerm_network_security_group` | nsg-mgmt, nsg-untrust, nsg-trust, nsg-ha, nsg-spoke1, nsg-spoke2 | 6 |
| networking | `azurerm_subnet_network_security_group_association` | – | 6 |
| networking | `azurerm_virtual_network_peering` | hub↔spoke1 (x2), hub↔spoke2 (x2) | 4 |
| networking | `azurerm_public_ip` | pip-external-lb, pip-fw1-mgmt, pip-fw2-mgmt, pip-panorama | 4 |
| bootstrap | `azurerm_storage_account` | stbootstrap\<random\> | 1 |
| bootstrap | `azurerm_storage_container` | bootstrap | 1 |
| bootstrap | `azurerm_storage_blob` | config/init-cfg.txt, config/authcodes | 2 |
| bootstrap | `azurerm_user_assigned_identity` | mi-panos-bootstrap | 1 |
| bootstrap | `azurerm_role_assignment` | Storage Blob Data Reader | 1 |
| panorama | `azurerm_network_interface` | nic-panorama | 1 |
| panorama | `azurerm_linux_virtual_machine` | vm-panorama | 1 |
| panorama | `azurerm_managed_disk` | datadisk-panorama-logs (2TB) | 1 |
| panorama | `azurerm_virtual_machine_data_disk_attachment` | – | 1 |
| firewall | `azurerm_marketplace_agreement` | paloaltonetworks/vmseries-flex/byol | 1 |
| firewall | `azurerm_availability_set` | avset-panos-fw-ha | 1 |
| firewall | `azurerm_network_interface` | nic-fw1-mgmt/untrust/trust/ha, nic-fw2-mgmt/untrust/trust/ha | 8 |
| firewall | `azurerm_linux_virtual_machine` | vm-panos-fw1, vm-panos-fw2 | 2 |
| firewall | `azurerm_network_interface_backend_address_pool_association` | – | 4 |
| loadbalancer | `azurerm_lb` | lb-external-panos, lb-internal-panos | 2 |
| loadbalancer | `azurerm_lb_backend_address_pool` | – | 2 |
| loadbalancer | `azurerm_lb_probe` | probe-http, probe-internal | 2 |
| loadbalancer | `azurerm_lb_rule` | rule-allports-external, rule-haports-internal | 2 |
| loadbalancer | `azurerm_lb_outbound_rule` | outbound-snat | 1 |
| frontdoor | `azurerm_cdn_frontdoor_profile` | afd-panos-transit | 1 |
| frontdoor | `azurerm_cdn_frontdoor_endpoint` | endpoint-panos-app | 1 |
| frontdoor | `azurerm_cdn_frontdoor_origin_group` | og-external-lb | 1 |
| frontdoor | `azurerm_cdn_frontdoor_origin` | origin-external-lb | 1 |
| frontdoor | `azurerm_cdn_frontdoor_route` | route-http | 1 |
| routing | `azurerm_route_table` | rt-spoke1-workload, rt-spoke2-workload | 2 |
| routing | `azurerm_route` | default-to-fw, spoke2-to-fw (Spoke1), default-to-fw, spoke1-to-fw (Spoke2) | 4 |
| routing | `azurerm_subnet_route_table_association` | – | 2 |
| spoke1_app | `azurerm_network_interface` | nic-spoke1-apache | 1 |
| spoke1_app | `azurerm_linux_virtual_machine` | vm-spoke1-apache (Ubuntu 22.04) | 1 |
| spoke2_dc | `azurerm_network_interface` | nic-spoke2-dc | 1 |
| spoke2_dc | `azurerm_windows_virtual_machine` | vm-spoke2-dc (Windows Server 2022) | 1 |
| spoke2_dc | `azurerm_virtual_machine_extension` | promote-to-dc (AD DS + DNS) | 1 |
| spoke2_dc | `azurerm_public_ip` | pip-bastion-spoke2 | 1 |
| spoke2_dc | `azurerm_bastion_host` | bastion-spoke2 (Standard SKU) | 1 |

</details>

---

## ✅ Wymagania wstępne

### Narzędzia

| Narzędzie | Minimalna wersja | Instalacja |
|-----------|:----------------:|-----------|
| [Terraform](https://www.terraform.io/downloads) | 1.5.0 | `brew install terraform` |
| [Azure CLI](https://docs.microsoft.com/cli/azure/install-azure-cli) | 2.50.0 | `brew install azure-cli` |
| [gh CLI](https://cli.github.com/) | 2.x | `brew install gh` |

### Uprawnienia Azure

- `Owner` **lub** `Contributor + User Access Administrator` na subskrypcjach Hub, Spoke1, Spoke2
- Dostęp do Azure Marketplace (akceptacja warunków VM-Series BYOL)

### Licencje Palo Alto Networks (BYOL)

Przed deploymentem musisz posiadać:
- **2x** licencję VM-Series (FW1 + FW2) – auth code do `terraform.tfvars` → `fw_auth_code`
- **1x** licencję Panorama – auth code do `terraform.tfvars` → `panorama_auth_code`

Licencje można uzyskać przez [Palo Alto Networks Customer Support Portal](https://support.paloaltonetworks.com/).

### Logowanie do Azure CLI

```bash
# Zaloguj się do Azure
az login

# Ustaw domyślną subskrypcję (jeśli masz kilka)
az account set --subscription "<hub_subscription_id>"

# Sprawdź zalogowaną sesję
az account show
```

---

## ⚙️ Konfiguracja zmiennych

### Krok 1 – Skopiuj szablon

```bash
cp terraform.tfvars.example terraform.tfvars
```

### Krok 2 – Wypełnij `terraform.tfvars`

```hcl
#------------------------------------------------------------------------------
# Azure Subscriptions (wymagane)
#------------------------------------------------------------------------------
hub_subscription_id    = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
spoke1_subscription_id = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"  # może być ten sam
spoke2_subscription_id = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"  # może być ten sam

#------------------------------------------------------------------------------
# Dane dostępu (wymagane)
#------------------------------------------------------------------------------
admin_username  = "panadmin"
admin_password  = "Str0ng!Passw0rd2024"   # min. 12 znaków, cyfry + specjalne

dc_admin_username = "dcadmin"
dc_admin_password = "DC-Str0ng!2024"      # Windows complexity requirements

#------------------------------------------------------------------------------
# Licencje PAN (BYOL - wymagane przed deployem)
#------------------------------------------------------------------------------
fw_auth_code       = "xxxx-xxxx-xxxx-xxxx"   # auth code VM-Series
panorama_auth_code = "xxxx-xxxx-xxxx-xxxx"   # auth code Panorama

#------------------------------------------------------------------------------
# Panorama bootstrap (uzupełnij po Phase 1)
#------------------------------------------------------------------------------
panorama_vm_auth_key    = ""   # wygeneruj w Panorama GUI po Phase 1
panorama_template_stack = "Transit-VNet-Stack"
panorama_device_group   = "Transit-VNet-DG"

#------------------------------------------------------------------------------
# Phase 2 – panorama_public_ip (zostaw puste dla Phase 1)
#------------------------------------------------------------------------------
panorama_public_ip = ""   # uzupełnij po Phase 1: terraform output panorama_public_ip
```

> **⚠️ WAŻNE**: `terraform.tfvars` zawiera hasła i auth codes – **nigdy nie commituj tego pliku do git!**
> Plik jest już wykluczony przez `.gitignore` w tym projekcie.

---

## 🚀 Wdrożenie – Phase 1 (Infrastruktura)

Phase 1 tworzy całą infrastrukturę Azure: sieci, VM-Series, Panorama, LB, Front Door, aplikacje.

### Krok 1 – Akceptuj Marketplace Agreement (jednorazowo per subskrypcja)

```bash
az vm image terms accept \
  --publisher paloaltonetworks \
  --offer vmseries-flex \
  --plan byol \
  --subscription "<hub_subscription_id>"
```

### Krok 2 – Sprawdź dostępność PAN-OS 11.1 w wybranym regionie

```bash
az vm image list \
  --publisher paloaltonetworks \
  --offer vmseries-flex \
  --sku byol \
  --location westeurope \
  --all \
  --query "[?contains(version, '11.1')]" \
  --output table
```

### Krok 3 – Inicjalizacja Terraform

```bash
terraform init
```

Terraform pobierze providery:
- `hashicorp/azurerm ~> 3.100`
- `hashicorp/random ~> 3.5`
- `PaloAltoNetworks/panos ~> 1.11`

### Krok 4 – Walidacja i formatowanie

```bash
terraform validate && terraform fmt -recursive
```

### Krok 5 – Podgląd planu

```bash
terraform plan -out=tfplan.phase1
```

Oczekiwana liczba zasobów: **~60 zasobów** do dodania.

### Krok 6 – Wdrożenie Phase 1

```bash
terraform apply \
  -target=module.networking \
  -target=module.bootstrap \
  -target=module.panorama \
  -target=module.loadbalancer \
  -target=module.firewall \
  -target=module.routing \
  -target=module.frontdoor \
  -target=module.spoke1_app \
  -target=module.spoke2_dc
```

> ⏱ **Czas wdrożenia**: ~15-20 minut (VM-Series i Windows DC trwają najdłużej)

### Krok 7 – Zapisz outputs Phase 1

```bash
terraform output
```

Przykładowy output:
```
apache_server_private_ip     = "10.1.0.4"
bastion_dns_name             = "bst-xxxx.bastion.azure.com"
bastion_public_ip            = "X.X.X.X"
bootstrap_storage_account    = "stbootstrapXXXXXX"
domain_controller_private_ip = "10.2.0.4"
domain_name                  = "panw.labs"
external_lb_public_ip        = "Y.Y.Y.Y"
frontdoor_endpoint_hostname  = "endpoint-panos-app-XXXXX.z01.azurefd.net"
fw1_management_public_ip     = "A.A.A.A"
fw2_management_public_ip     = "B.B.B.B"
internal_lb_private_ip       = "10.0.2.100"
panorama_private_ip          = "10.0.0.10"
panorama_public_ip           = "C.C.C.C"   ← potrzebne do Phase 2
spoke1_route_table_name      = "rt-spoke1-workload"
spoke2_route_table_name      = "rt-spoke2-workload"
```

---

## 🔧 Wdrożenie – Phase 2 (Panorama Config)

> **Poczekaj ~10 minut** od zakończenia Phase 1 zanim zaczniesz Phase 2 – Panorama i VM-Series potrzebują czasu na bootstrap.

### Krok 1 – Sprawdź dostępność Panorama

```bash
# Panorama IP z outputu Phase 1
PANORAMA_IP=$(terraform output -raw panorama_public_ip)

# Sprawdź dostępność HTTPS (GUI Panorama)
curl -k --connect-timeout 10 https://$PANORAMA_IP
```

Gdy Panorama odpowiada, kontynuuj.

### Krok 2 – Zaloguj się do Panorama i wygeneruj VM Auth Key

1. Otwórz przeglądarkę: `https://<panorama_public_ip>`
2. Zaloguj się (admin / hasło z `terraform.tfvars`)
3. Przejdź do: **Panorama → Device Registration Auth Key**
4. Kliknij **Generate** – skopiuj wygenerowany klucz

### Krok 3 – Zaktualizuj `terraform.tfvars`

```hcl
panorama_public_ip   = "C.C.C.C"          # z terraform output
panorama_vm_auth_key = "xxxx-xxxx-xxxx"   # z Panorama GUI
```

### Krok 4 – Zweryfikuj połączenie FW → Panorama

W Panorama GUI: **Panorama → Managed Devices** – FW1 i FW2 powinny pojawić się jako "Connected".

### Krok 5 – Wdroż konfigurację Panorama

```bash
terraform apply   # tym razem bez -target → dodaje module.panorama_config
```

Terraform skonfiguruje w Panorama:
- ✅ Template `Transit-VNet-Template` + Template Stack `Transit-VNet-Stack`
- ✅ Device Group `Transit-VNet-DG`
- ✅ Interfejsy: ethernet1/1 (untrust), ethernet1/2 (trust), ethernet1/3 (HA2)
- ✅ Strefy: `untrust`, `trust`
- ✅ Virtual Router `default` ze statycznymi trasami do Spoke1, Spoke2, internetu
- ✅ NAT rules: DNAT HTTP/HTTPS → Apache 10.1.0.4, SNAT outbound
- ✅ Security rules: Allow Inbound Web, East-West Spoke↔Spoke, Outbound, Deny-All

### Krok 6 – Commit i Push konfiguracji w Panorama

1. W Panorama GUI kliknij **Commit** → **Commit and Push**
2. Wybierz Template Stack i Device Group → **Push Now**

---

## 🔍 Weryfikacja po wdrożeniu

### Test 1 – Hello World via Azure Front Door

```bash
AFD_HOSTNAME=$(terraform output -raw frontdoor_endpoint_hostname)
curl -s http://$AFD_HOSTNAME | grep "HELLO WORLD"
```

Oczekiwany wynik: strona HTML z tytułem „Palo Alto Networks – Transit VNet Demo".

### Test 2 – Bezpośredni test External LB

```bash
EXT_LB_IP=$(terraform output -raw external_lb_public_ip)
curl -s http://$EXT_LB_IP | grep "HELLO WORLD"
```

### Test 3 – Dostęp RDP do Domain Controller przez Bastion

1. Otwórz [Azure Portal](https://portal.azure.com)
2. Przejdź do: **Virtual Machines → vm-spoke2-dc → Connect → Bastion**
3. Zaloguj się: `dcadmin` / hasło z `terraform.tfvars`
4. Zweryfikuj domenę: `Get-ADDomain` w PowerShell → powinno zwrócić `panw.labs`

### Test 4 – East-West (Spoke1 → Spoke2)

```bash
# Z FW1 Management lub przez Bastion – ping z maszyny w Spoke1 do DC
# Sprawdź w PAN-OS Monitor → Traffic logs – ruch powinien przechodzić przez FW
```

### Test 5 – Panorama zarządzanie FW

```bash
PANORAMA_IP=$(terraform output -raw panorama_public_ip)
# Otwórz: https://$PANORAMA_IP
# Panorama → Managed Devices → powinny widnieć FW1 i FW2 ze statusem "Connected"
```

---

## 📤 Outputs

Po wdrożeniu uruchom `terraform output` aby uzyskać:

| Output | Opis | Użycie |
|--------|------|--------|
| `panorama_public_ip` | IP Panorama | GUI: `https://<ip>`, Phase 2 tfvars |
| `panorama_private_ip` | IP prywatny Panorama | Bootstrap init-cfg.txt `panorama-server` |
| `fw1_management_public_ip` | IP zarządzania FW1 | GUI: `https://<ip>` |
| `fw2_management_public_ip` | IP zarządzania FW2 | GUI: `https://<ip>` |
| `external_lb_public_ip` | IP External LB | Inbound traffic entry point |
| `internal_lb_private_ip` | IP Internal LB (10.0.2.100) | UDR next-hop w Spoke VNetach |
| `frontdoor_endpoint_hostname` | Hostname AFD | URL aplikacji Hello World |
| `apache_server_private_ip` | IP Apache (10.1.0.4) | DNAT target w NAT policy |
| `domain_controller_private_ip` | IP DC (10.2.0.4) | User-ID Agent, DNS |
| `bastion_dns_name` | DNS Bastion | RDP via Azure Portal |
| `bootstrap_storage_account` | Nazwa storage account | Bootstrap diagnostics |
| `spoke1_route_table_name` | Route table Spoke1 | Weryfikacja UDR |
| `spoke2_route_table_name` | Route table Spoke2 | Weryfikacja UDR |

---

## 🗑 Usunięcie infrastruktury

```bash
# Usuń całą infrastrukturę (wymaga potwierdzenia 'yes')
terraform destroy

# Lub z auto-approve (ostrożnie!)
terraform destroy -auto-approve
```

> ⏱ Usuwanie trwa ~15-20 minut. Kolejność jest odwrotna do tworzenia.

---

## 🔐 Bezpieczeństwo

### Zalecenia dla środowisk produkcyjnych

1. **NSG Management** – ogranicz `source_address_prefix` do konkretnego IP jump hosta lub VPN:
   ```hcl
   # W modules/networking/main.tf zmień:
   source_address_prefix = "YOUR.JUMP.HOST.IP/32"
   ```

2. **Hasła i auth codes** – zamiast `terraform.tfvars` użyj:
   ```bash
   export TF_VAR_admin_password="YourPassword"
   export TF_VAR_fw_auth_code="xxxx-xxxx"
   ```
   lub użyj **Azure Key Vault** z data source.

3. **Remote State Backend** – nie trzymaj state lokalnie:
   ```hcl
   terraform {
     backend "azurerm" {
       resource_group_name  = "rg-terraform-state"
       storage_account_name = "stterraformstate"
       container_name       = "tfstate"
       key                  = "azure-transit-vnet-ha.tfstate"
     }
   }
   ```

4. **terraform.tfvars** – jest już w `.gitignore`. Nigdy nie usuwaj tego wpisu.

5. **Panorama dostęp** – w produkcji ogranicz NSG dla Panorama do konkretnych IP administratorów.

6. **Azure Policy** – rozważ przypisanie polityk wymagających szyfrowania, tagów, regionów.

---

## 📚 Źródła

- [Palo Alto Networks: Azure Transit VNet Deployment Guide](https://www.paloaltonetworks.com/apps/pan/public/downloadResource?pagePath=/content/pan/en_US/resources/guides/azure-transit-vnet-deployment-guide)
- [Azure Standard Load Balancer Documentation](https://docs.microsoft.com/azure/load-balancer/)
- [Azure Front Door Premium](https://docs.microsoft.com/azure/frontdoor/)
- [Terraform panos Provider](https://registry.terraform.io/providers/PaloAltoNetworks/panos/latest/docs)
- [Terraform azurerm Provider](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs)

---

## 📄 Licencja

Projekt dostępny na licencji MIT. Szczegóły w pliku [LICENSE](LICENSE).

---

*Autor: Demo Reference Architecture | Palo Alto Networks VM-Series HA on Azure*
