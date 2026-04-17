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
2. [Komponenty projektu](#-komponenty-projektu)
3. [Wymagania wstępne](#-wymagania-wstępne)
4. [🚨 Destroy – jak usunąć całą infrastrukturę](#-destroy--jak-usunąć-całą-infrastrukturę)
5. [Konfiguracja zmiennych](#-konfiguracja-zmiennych)
6. [Wdrożenie – Phase 1a (Sieć + Panorama)](#-wdrożenie--phase-1a-sieć--panorama)
7. [Wdrożenie – Phase 1b (Bootstrap + Firewalle + Spokes)](#-wdrożenie--phase-1b-bootstrap--firewalle--spokes)
8. [Wdrożenie – Phase 2 (Konfiguracja Panoramy)](#-wdrożenie--phase-2-konfiguracja-panoramy)
9. [Weryfikacja po wdrożeniu](#-weryfikacja-po-wdrożeniu)
10. [Rozwiązywanie problemów](#-rozwiązywanie-problemów)
11. [Bezpieczeństwo](#-bezpieczeństwo)
12. [Zasoby Azure](#-zasoby-azure)

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
        │ HTTP/HTTPS       │  │  nic-fw1-untrust (10.0.1.4)                         │   │
        ▼                  │  │  nic-fw2-untrust (10.0.1.5)                         │   │
 ┌─────────────┐          │  └──────────────────────────────────────────────────────┘   │
 │External LB  │ ◄────────┤                                                             │
 │pip-ext-lb   │          │  ┌──────────── snet-trust  10.0.2.0/24 ────────────────┐   │
 └─────────────┘          │  │  nic-fw1-trust (10.0.2.4)                           │   │
        │                  │  │  nic-fw2-trust (10.0.2.5)                           │   │
        │                  │  │  lb-internal-panos (10.0.2.100) ← UDR next-hop     │   │
        │                  │  └────────────────────────────────────────────────────┘   │
        │                  │                                                             │
        │                  │  ┌──────────── snet-ha  10.0.3.0/24 ──────────────────┐   │
        │                  │  │  nic-fw1-ha ──HA2── nic-fw2-ha                     │   │
        │                  │  └────────────────────────────────────────────────────┘   │
        │                  └──────────────────────────────┬──────────────────────────────┘
        │                                                  │
        │                               VNet Peering (bidirectional)
        │                     ┌──────────────┴──────────────────────┐
        │                     │                                      │
        │       ┌─────────────▼────────────┐         ┌──────────────▼──────────────┐
        │       │  Spoke1 VNet             │         │  Spoke2 VNet                 │
        │       │  10.1.0.0/16             │         │  10.2.0.0/16                 │
        │       │  snet-workload /24       │         │  snet-workload /24           │
        │       │  UDR: 0/0 → 10.0.2.100  │◄───────►│  UDR: 0/0 → 10.0.2.100     │
        │       │                          │         │  AzureBastionSubnet /26      │
        │       │  vm-spoke1-apache        │         │  vm-spoke2-dc (Win 2022)    │
        │       │  (Ubuntu, Apache2)       │         │  panw.labs AD Domain         │
        └──────►│  10.1.0.4               │         │  10.2.0.4                    │
         DNAT   └──────────────────────────┘         │  Azure Bastion (Standard)    │
                ↑ Hello World App                    └──────────────────────────────┘
                  AFD → Ext LB → VM-Series (DNAT) → Apache
```

### Przepływy ruchu

| Typ ruchu | Ścieżka | Inspekcja FW |
|-----------|---------|:---:|
| **Inbound HTTP/HTTPS** | Client → AFD → External LB → VM-Series (DNAT) → Apache 10.1.0.4 | ✅ |
| **Outbound Internet** | App (Spoke) → UDR → Internal LB → VM-Series (SNAT) → Internet | ✅ |
| **East-West Spoke→Spoke** | Spoke1 → UDR → Internal LB → VM-Series → Spoke2 | ✅ |
| **Management** | Admin → pip-fw1/fw2-mgmt → PAN-OS GUI/SSH | – |
| **Panorama mgmt** | Admin → pip-panorama → Panorama GUI | – |
| **DC RDP** | Admin → Azure Portal Bastion → vm-spoke2-dc | – |

---

## 📦 Komponenty projektu

| Moduł | Opis | Kluczowe zasoby |
|-------|------|-----------------|
| **`networking`** | Sieć – Hub i oba Spoke VNety | 3x VNet, 7x Subnet, 6x NSG, 4x VNet Peering, 3x Public IP |
| **`panorama`** | Serwer zarządzania Panorama | VM (Standard_D4s_v3), OS 256 GB, 2TB data disk, Public IP |
| **`bootstrap`** | Paczka bootstrap dla VM-Series | Storage Account (network_rules=Deny), blobs (init-cfg, authcodes), User-Assigned Managed Identity |
| **`firewall`** | Para HA VM-Series | 2x VM PAN-OS latest (8 vCPU), Availability Set, 4 NIC/VM |
| **`loadbalancer`** | Balansery ruchu | External Standard LB (TCP 80/443) + Internal Standard LB (HA Ports, 10.0.2.100) |
| **`routing`** | Routing Spoke VNetów | 2x UDR Route Table (domyślna trasa + east-west → Internal LB) |
| **`frontdoor`** | Globalny wejście HTTP/HTTPS | Azure Front Door Premium, Endpoint, Origin Group, Route |
| **`spoke1_app`** | Aplikacja demonstracyjna | Ubuntu 22.04, Apache2 Hello World (cloud-init), IP 10.1.0.4 |
| **`spoke2_dc`** | Kontroler domeny | Windows Server 2022, AD DS (panw.labs), Azure Bastion Standard |
| **`panorama_config`** | Konfiguracja Panorama (Phase 2) | Template, Device Group, Strefy, VR, Static Routes, NAT, Security Policy |

---

## ✅ Wymagania wstępne

### Narzędzia

| Narzędzie | Min. wersja | Instalacja |
|-----------|:-----------:|-----------|
| [Terraform](https://www.terraform.io/downloads) | 1.5.0 | `brew install terraform` |
| [Azure CLI](https://docs.microsoft.com/cli/azure/install-azure-cli) | 2.50.0 | `brew install azure-cli` |

### Uprawnienia Azure

- `Owner` **lub** `Contributor + User Access Administrator` na subskrypcjach Hub, Spoke1, Spoke2
- Dostęp do Azure Marketplace (akceptacja warunków VM-Series BYOL – wykonywane automatycznie przez Terraform via `az vm image terms accept`)

### Licencje Palo Alto Networks (BYOL)

Przed deploymentem musisz posiadać (z [Palo Alto Customer Support Portal](https://support.paloaltonetworks.com/)):
- **2x** auth code VM-Series BYOL → `fw_auth_code` w `terraform.tfvars`
- **1x** auth code Panorama BYOL → `panorama_auth_code` w `terraform.tfvars`

### Logowanie do Azure CLI

```bash
az login
az account set --subscription "<hub_subscription_id>"
az account show --query "{Sub:id, Name:name}" -o table
```

---

## 🚨 Destroy – jak usunąć całą infrastrukturę

> **Uruchom to w OSOBNYM terminalu i zostaw działać w tle (20-40 min)**

### Opcja A – przez Terraform (zalecana)

```bash
cd /Users/mzalewski/TF/azure_ha_project

# Usuń wszystkie zasoby (bez pytania o potwierdzenie)
terraform destroy -auto-approve 2>&1 | tee destroy.log

# Monitoruj w innym oknie:
tail -f destroy.log | grep -E "(Destroying|Destroyed|Error)"
```

### Opcja B – przez Azure CLI (gdy state jest uszkodzony)

```bash
# Usuń resource groups (zawiera 95% zasobów) – wykonuje się równolegle
az group delete --name rg-transit-hub  --yes --no-wait
az group delete --name rg-spoke1-app   --yes --no-wait
az group delete --name rg-spoke2-dc    --yes --no-wait

# Poczekaj na usunięcie (sprawdzaj status)
watch -n 30 "az group list --query \"[?name=='rg-transit-hub'||name=='rg-spoke1-app'||name=='rg-spoke2-dc'].{Name:name,State:properties.provisioningState}\" -o table"
```

### Opcja C – Czyść state po destroy przez CLI

Jeśli destroy przez CLI (Opcja B) się powiodło ale state Terraform nadal zawiera zasoby:
```bash
# Wyczyść lokalny state
terraform state list | xargs -I {} terraform state rm {}

# LUB po prostu usuń pliki state (TYLKO jeśli nie używasz remote backend)
rm terraform.tfstate terraform.tfstate.backup
```

### Po destroy – przygotuj środowisko do nowego deploy

```bash
# Sprawdź czy resource groups naprawdę zniknęły
az group list --query "[?name=='rg-transit-hub'||name=='rg-spoke1-app'||name=='rg-spoke2-dc']" -o table

# Gdy puste – reinitializuj Terraform (czyści provider cache)
terraform init -reconfigure
```

---

## ⚙️ Konfiguracja zmiennych

### Krok 1 – Skopiuj szablon

```bash
cp terraform.tfvars.example terraform.tfvars
```

### Krok 2 – Wypełnij `terraform.tfvars`

```hcl
# ═══════════════════════════════════════════════════════════
# SEKCJA OBOWIĄZKOWA – uzupełnij przed deploy
# ═══════════════════════════════════════════════════════════

hub_subscription_id    = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
spoke1_subscription_id = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"  # może być ten sam co hub
spoke2_subscription_id = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"  # może być ten sam co hub

admin_username = "panadmin"
admin_password = "Str0ng!Password2024"   # min 12 znaków, wielkie+małe+cyfry+special

dc_admin_username = "dcadmin"
dc_admin_password = "DC-Str0ng!2024"

fw_auth_code       = "I1234567-XXXX-XXXX-XXXX"   # z CSP Portal → Assets → Auth Codes
panorama_auth_code = "P7654321-XXXX-XXXX-XXXX"   # z CSP Portal → Assets → Auth Codes

# Twój publiczny IP (wymagane przez Azure Policy dla Storage Account):
#   curl -s https://api.ipify.org
terraform_operator_ips = ["X.X.X.X"]

# ═══════════════════════════════════════════════════════════
# SEKCJA UZUPEŁNIANA PO PHASE 1a (Panorama uruchomiona)
# ═══════════════════════════════════════════════════════════

# Wygeneruj w Panoramie: Panorama → Device Registration Auth Key → Generate
# Zostaw "" dla Phase 1a, uzupełnij przed Phase 1b
panorama_vm_auth_key = ""

# ═══════════════════════════════════════════════════════════
# SEKCJA OPCJONALNA – wartości domyślne działają dla demo
# ═══════════════════════════════════════════════════════════

location               = "West Europe"
fw_vm_size             = "Standard_D8s_v3"  # 8 vCPU, 32 GB RAM
pan_os_version         = "latest"           # zawsze najnowsza niewyofana wersja

panorama_vm_size       = "Standard_D4s_v3"
panorama_template_stack = "Transit-VNet-Stack"
panorama_device_group   = "Transit-VNet-DG"

dc_domain_name         = "panw.labs"
dc_skip_auto_promote   = false  # ustaw true jeśli DC jest już promowany (state drift)
```

> **⚠️ WAŻNE**: `terraform.tfvars` zawiera hasła i auth codes – **nigdy nie commituj tego pliku do git!**
> Plik jest wykluczony przez `.gitignore`.

---

## 🚀 Wdrożenie – Phase 1a (Sieć + Panorama)

> **CEL**: Uruchomić Panoramę w Azure, by uzyskać z niej `vm-auth-key` potrzebny do bootstrap VM-Series.

### Krok 1 – Inicjalizacja Terraform

```bash
cd /Users/mzalewski/TF/azure_ha_project
terraform init
```

Terraform pobierze providery:
- `hashicorp/azurerm ~> 3.100`
- `hashicorp/random ~> 3.5`
- `hashicorp/null ~> 3.2`

### Krok 2 – Walidacja

```bash
terraform validate && terraform fmt -recursive
echo "Validate OK ✓"
```

### Krok 3 – Deploy Panoramy i sieci

```bash
terraform apply \
  -target=azurerm_resource_group.hub \
  -target=azurerm_resource_group.spoke1 \
  -target=azurerm_resource_group.spoke2 \
  -target=module.networking \
  -target=module.panorama
```

> ⏱ **Czas**: ~5-8 minut. Tworzy ~25 zasobów (VNety, subnety, NSG, Panorama VM).

### Krok 4 – Pobierz IP Panoramy i poczekaj na boot

```bash
PANORAMA_IP=$(terraform output -raw panorama_public_ip)
echo "Panorama IP: $PANORAMA_IP"

# Sprawdzaj co 2 min aż do odpowiedzi HTTPS (~10-15 min od uruchomienia VM)
until curl -sk --connect-timeout 5 https://$PANORAMA_IP -o /dev/null; do
  echo "$(date): Panorama nie gotowa, czekam 120s..."
  sleep 120
done
echo "✅ Panorama HTTPS dostępna!"
```

### Krok 5 – Aktywuj licencję Panoramy i wygeneruj VM Auth Key

1. Otwórz przeglądarkę: `https://<PANORAMA_IP>`
2. Zaloguj się: `panadmin` / hasło z `terraform.tfvars`
3. **Aktywacja licencji** (jeśli auth code nie zadziałał z init-cfg):
   - `Panorama → Licenses → Activate feature using auth code`
   - Wpisz `panorama_auth_code`
4. **Wygeneruj VM Auth Key**:
   - `Panorama → Device Registration Auth Key → Generate`
   - Ustaw ważność: **8760 hours** (1 rok)
   - Skopiuj klucz (format: `XXXXXXXXXXXXXXXXXXXXXXXXXXX`)

### Krok 6 – Zaktualizuj `terraform.tfvars`

```hcl
# Wklej skopiowany klucz:
panorama_vm_auth_key = "SKOPIOWANY-VM-AUTH-KEY"
```

---

## 🚀 Wdrożenie – Phase 1b (Bootstrap + Firewalle + Spokes)

> **CEL**: Wdrożyć resztę infrastruktury – VM-Series startują z prawidłowym bootstrap zawierającym `vm-auth-key`.

### Krok 1 – Wdróż bootstrap (zaktualizuje init-cfg.txt z vm-auth-key)

```bash
terraform apply -target=module.bootstrap
```

> ⏱ ~1-2 min. Tworzy Storage Account i uploady bootstrap blobs.

**Jeśli Azure Policy blokuje Storage Account** (błąd 403/deny):
- Upewnij się że `terraform_operator_ips` zawiera Twój publiczny IP
- Sprawdź: `curl -s https://api.ipify.org`

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

> ⏱ **Czas**: ~15-25 minut.
>
> - **VM-Series (FW1, FW2)**: ~5 min deploy + ~15 min bootstrap/PAN-OS boot
> - **Windows DC**: ~5 min deploy + ~30-45 min AD DS promotion
> - **Azure Bastion**: ~5-8 min

**Jeśli DC extension timeout** (po 60 min):
```hcl
# terraform.tfvars:
dc_skip_auto_promote = true
```
```bash
terraform apply -target=module.spoke2_dc
```
DC jest promowany w tle – extension działało mimo że Terraform przekroczył timeout.

### Krok 3 – Sprawdź outputs

```bash
terraform output
```

Przykład:
```
apache_server_private_ip     = "10.1.0.4"
bastion_dns_name             = "bst-xxxx.bastion.azure.com"
external_lb_public_ip        = "1.2.3.4"
frontdoor_endpoint_hostname  = "endpoint-panos-app-xxxxx.z01.azurefd.net"
fw1_management_public_ip     = "5.6.7.8"
fw2_management_public_ip     = "9.10.11.12"
internal_lb_private_ip       = "10.0.2.100"
panorama_public_ip           = "13.14.15.16"
```

### Krok 4 – Zweryfikuj że VM-Series zarejestrowały się w Panoramie

1. Otwórz Panorama: `https://<panorama_public_ip>`
2. Przejdź do: `Panorama → Managed Devices → Summary`
3. FW1 (`fw1-transit-hub`) i FW2 (`fw2-transit-hub`) powinny mieć status **Connected** ✅

> Jeśli FW nie pojawiają się po 15 min od zakończenia deploy:
> - Sprawdź czy `panorama_vm_auth_key` był poprawny
> - Sprawdź logi bootstrap: w Panorama GUI → `Monitor → System`
> - Można re-deploying bootstrap: `terraform apply -target=module.bootstrap` (FW musi być zrestartowany)

---

## 🔧 Wdrożenie – Phase 2 (Konfiguracja Panoramy)

> **Poczekaj 15-20 min** od zakończenia Phase 1b – VM-Series potrzebują czasu na bootstrap i rejestrację w Panoramie.

### Krok 1 – Przygotuj `phase2-panorama-config/terraform.tfvars`

```bash
cd phase2-panorama-config
cp terraform.tfvars.example terraform.tfvars
```

```hcl
# phase2-panorama-config/terraform.tfvars
panorama_hostname = "<panorama_public_ip>"    # z terraform output (Phase 1)
panorama_username = "panadmin"
panorama_password = "<admin_password>"        # to samo co w Phase 1

template_name       = "Transit-VNet-Template"
template_stack_name = "Transit-VNet-Stack"
device_group_name   = "Transit-VNet-DG"

trust_subnet_cidr   = "10.0.2.0/24"
untrust_subnet_cidr = "10.0.1.0/24"
spoke1_vnet_cidr    = "10.1.0.0/16"
spoke2_vnet_cidr    = "10.2.0.0/16"

apache_server_ip      = "10.1.0.4"
external_lb_public_ip = "<external_lb_public_ip>"  # z terraform output (Phase 1)
```

### Krok 2 – Deploy konfiguracji Panoramy

```bash
cd phase2-panorama-config
terraform init
terraform apply
```

Terraform skonfiguruje w Panoramie:
- ✅ Template `Transit-VNet-Template` + Template Stack `Transit-VNet-Stack`
- ✅ Device Group `Transit-VNet-DG`
- ✅ Interfejsy: ethernet1/1 (untrust), ethernet1/2 (trust), ethernet1/3 (HA2)
- ✅ Strefy: `untrust`, `trust`
- ✅ Virtual Router ze statycznymi trasami do Spoke1, Spoke2, internetu
- ✅ NAT rules: DNAT HTTP/HTTPS → Apache 10.1.0.4, SNAT outbound
- ✅ Security rules: Allow Inbound Web, East-West, Outbound, Deny-All

### Krok 3 – Commit i Push konfiguracji w Panoramie

1. W Panorama GUI kliknij **Commit → Commit and Push**
2. Wybierz: Template Stack + Device Group → **Push Now**
3. Poczekaj na **Push Success** na FW1 i FW2

---

## 🔍 Weryfikacja po wdrożeniu

### Test 1 – Hello World via Azure Front Door

```bash
AFD_HOSTNAME=$(terraform output -raw frontdoor_endpoint_hostname 2>/dev/null || echo "BRAK")
curl -s "https://$AFD_HOSTNAME" | grep "HELLO WORLD" && echo "✅ AFD OK" || echo "❌ AFD FAIL"
```

### Test 2 – Bezpośredni test External LB

```bash
EXT_LB_IP=$(terraform output -raw external_lb_public_ip)
curl -s --connect-timeout 10 http://$EXT_LB_IP | grep "HELLO WORLD" && echo "✅ Ext LB OK"
```

### Test 3 – Panorama zarządzanie FW

```
Panorama GUI → Managed Devices → Summary
FW1 i FW2: Connected ✅, Policy Sync: In Sync ✅
```

### Test 4 – DC przez Azure Bastion

1. Azure Portal → Virtual Machines → vm-spoke2-dc → Connect → Bastion
2. Login: `dcadmin` / hasło z tfvars
3. W PowerShell: `Get-ADDomain | Select Name, DomainMode` → powinno zwrócić `panw.labs`

### Test 5 – East-West (Spoke1 → Spoke2)

```bash
# Z vm-spoke1-apache (przez SSH z zarządzania lub bastion):
ping 10.2.0.4  # DC w Spoke2
# Sprawdź logi w: PAN-OS Monitor → Traffic → filtr "addr.dst in 10.2.0.0/16"
```

---

## 🔧 Rozwiązywanie problemów

### Problem 1: Storage Account 403 – "Azure Policy: Deny"

**Objaw**: `Error: performing CreateOrUpdate on Storage Account: 403 RequestDisallowed by Policy`

**Przyczyna**: Azure Policy wymaga `network_rules.default_action = "Deny"`. Terraform operator nie ma dostępu do uploadu blobów.

**Rozwiązanie**:
```bash
# Znajdź swój publiczny IP
curl -s https://api.ipify.org

# Dodaj do terraform.tfvars:
terraform_operator_ips = ["TWÓJ.IP"]

terraform apply -target=module.bootstrap
```

---

### Problem 2: ImageVersionDeprecated – "11.1.4 is deprecated"

**Objaw**: `unexpected status 404 with error: ImageVersionDeprecated`

**Rozwiązanie**: Użyj `"latest"` (domyślne od tej wersji projektu):
```hcl
pan_os_version = "latest"
```

Sprawdź dostępne wersje:
```bash
az vm image list --publisher paloaltonetworks --offer vmseries-flex \
  --sku byol --all --query "[].version" -o tsv | sort -V | tail -10
```

---

### Problem 3: State drift – "already exists – needs to be imported"

**Objaw**: `Error: A resource with the ID "..." already exists`

**Przyczyna**: Zasób istnieje w Azure ale nie ma go w Terraform state (częściowy apply, timeout).

**Rozwiązanie – automatyczny skrypt**:
```bash
chmod +x scripts/fix-drift.sh
./scripts/fix-drift.sh
terraform apply
```

**Rozwiązanie – ręczne**:
```bash
# Dla dc_promote extension:
SUB=$(az account show --query id -o tsv)
terraform import module.spoke2_dc.azurerm_virtual_machine_extension.dc_promote[0] \
  "/subscriptions/$SUB/resourceGroups/rg-spoke2-dc/providers/Microsoft.Compute/virtualMachines/vm-spoke2-dc/extensions/promote-to-dc"
```

---

### Problem 4: External LB – "All Ports rule not allowed on public LB"

**Objaw**: `Error: The property 'AllocationMethod' is not valid ... AllPorts is not supported`

**Status**: ✅ NAPRAWIONE w tej wersji projektu.

External LB używa reguł TCP 80 i TCP 443 (nie HA Ports).
Internal LB nadal używa HA Ports (dozwolone dla internal LB).

---

### Problem 5: DC extension timeout

**Objaw**: `context deadline exceeded` po 60+ minutach

**Przyczyna**: AD DS promotion zajmuje 30-45 min. Extension jest uruchamiany, DC jest promowany, ale TF może przekroczyć timeout.

**Rozwiązanie**:
```hcl
# terraform.tfvars – jeśli extension już istnieje w Azure:
dc_skip_auto_promote = true
```
```bash
terraform apply -target=module.spoke2_dc

# Zweryfikuj DC przez Bastion:
# Get-ADDomain | Select Name, DomainMode
```

---

### Problem 6: VM-Series nie rejestruje się w Panoramie

**Objaw**: FW nie pojawia się w Panorama → Managed Devices po 20+ min

**Możliwe przyczyny i rozwiązania**:

1. **Pusty `panorama_vm_auth_key`** podczas tworzenia VM:
   - Dodaj klucz do tfvars: `panorama_vm_auth_key = "KLUCZ"`
   - Zaktualizuj bootstrap: `terraform apply -target=module.bootstrap`
   - FW musi być **zrestartowany** by ponownie odczytał bootstrap

2. **NSG blokuje ruch Panorama ↔ FW** (port 3978):
   - Sprawdź `nsg-mgmt` – powinien zezwalać na ruch w obrębie `snet-mgmt`
   - Panorama i FW są w tej samej podsieci (`10.0.0.0/24`)

3. **Nieprawidłowy klucz lub klucz wygasł**:
   - Wygeneruj nowy w: `Panorama → Device Registration Auth Key`
   - Sprawdź datę ważności klucza

---

### Problem 7: Marketplace agreement – "already exists"

**Status**: ✅ NAPRAWIONE w tej wersji projektu.

Zamiast `azurerm_marketplace_agreement` (który fails gdy umowa już istnieje) używamy `null_resource` z `az vm image terms accept` – komenda jest idempotentna.

---

## 🔐 Bezpieczeństwo

### Zalecenia produkcyjne

1. **NSG Management** – ogranicz `source_address_prefix` do IP jump hosta/VPN:
   ```
   # modules/networking/main.tf → azurerm_network_security_group.mgmt
   source_address_prefix = "YOUR.JUMP.HOST.IP/32"
   ```

2. **Hasła i auth codes** – użyj zmiennych środowiskowych zamiast `terraform.tfvars`:
   ```bash
   export TF_VAR_admin_password="YourPassword"
   export TF_VAR_fw_auth_code="xxxx-xxxx"
   export TF_VAR_panorama_auth_code="yyyy-yyyy"
   ```

3. **Remote State Backend** – nie trzymaj state lokalnie:
   ```hcl
   # providers.tf → dodaj backend block
   backend "azurerm" {
     resource_group_name  = "rg-terraform-state"
     storage_account_name = "stterraformstate"
     container_name       = "tfstate"
     key                  = "azure-transit-vnet-ha.tfstate"
   }
   ```

4. **`terraform.tfvars`** – jest w `.gitignore`. Nigdy nie usuwaj tego wpisu.

5. **Panorama dostęp** – ogranicz NSG dla Panorama public IP do znanych adminów.

6. **`terraform_operator_ips`** – odśwież IP gdy zmienisz lokalizację (np. praca zdalna).

---

## 🗂 Zasoby Azure

<details>
<summary><b>Kliknij, aby rozwinąć pełną listę zasobów (~65 obiektów Azure)</b></summary>

| Moduł | Typ zasobu | Opis | Ilość |
|-------|-----------|------|:-----:|
| networking | `azurerm_virtual_network` | vnet-transit-hub, vnet-spoke1, vnet-spoke2 | 3 |
| networking | `azurerm_subnet` | snet-mgmt, snet-untrust, snet-trust, snet-ha, snet-spoke1-wl, snet-spoke2-wl, AzureBastionSubnet | 7 |
| networking | `azurerm_network_security_group` | nsg-mgmt, nsg-untrust, nsg-trust, nsg-ha, nsg-spoke1, nsg-bastion-spoke2, nsg-spoke2 | 7 |
| networking | `azurerm_subnet_network_security_group_association` | – | 6 |
| networking | `azurerm_virtual_network_peering` | hub↔spoke1 (x2), hub↔spoke2 (x2) | 4 |
| networking | `azurerm_public_ip` | pip-external-lb, pip-fw1-mgmt, pip-fw2-mgmt | 3 |
| panorama | `azurerm_public_ip` | pip-panorama-mgmt | 1 |
| panorama | `azurerm_network_interface` | nic-panorama-mgmt | 1 |
| panorama | `azurerm_linux_virtual_machine` | vm-panorama (Standard_D4s_v3) | 1 |
| panorama | `azurerm_managed_disk` | disk-panorama-logs (2 TB) | 1 |
| panorama | `azurerm_virtual_machine_data_disk_attachment` | – | 1 |
| panorama | `null_resource` | accept_panorama_terms (az cli, idempotent) | 1 |
| bootstrap | `random_string` | sa_suffix | 1 |
| bootstrap | `azurerm_storage_account` | sapanosbstrap\<rnd\> (network_rules=Deny) | 1 |
| bootstrap | `azurerm_storage_container` | bootstrap | 1 |
| bootstrap | `azurerm_storage_blob` | fw1/config/init-cfg.txt, fw1/license/authcodes, fw1/software/.placeholder, fw1/content/.placeholder (i analogicznie fw2) | 8 |
| bootstrap | `azurerm_user_assigned_identity` | id-fw-bootstrap | 1 |
| bootstrap | `azurerm_role_assignment` | Storage Blob Data Reader | 1 |
| firewall | `null_resource` | accept_panos_terms (az cli, idempotent) | 1 |
| firewall | `azurerm_availability_set` | avset-panos-fw-ha | 1 |
| firewall | `azurerm_network_interface` | nic-fw1-mgmt/untrust/trust/ha, nic-fw2-mgmt/untrust/trust/ha | 8 |
| firewall | `azurerm_linux_virtual_machine` | vm-panos-fw1, vm-panos-fw2 (Standard_D8s_v3) | 2 |
| firewall | `azurerm_network_interface_backend_address_pool_association` | fw1+fw2 untrust→Ext LB, fw1+fw2 trust→Int LB | 4 |
| loadbalancer | `azurerm_lb` | lb-external-panos (public), lb-internal-panos (private) | 2 |
| loadbalancer | `azurerm_lb_backend_address_pool` | – | 2 |
| loadbalancer | `azurerm_lb_probe` | probe-http (Ext), probe-internal (Int) | 2 |
| loadbalancer | `azurerm_lb_rule` | rule-http-inbound (TCP/80), rule-https-inbound (TCP/443), rule-haports-internal | 3 |
| loadbalancer | `azurerm_lb_outbound_rule` | outbound-snat | 1 |
| frontdoor | `azurerm_cdn_frontdoor_profile` | afd-panos-transit (Premium) | 1 |
| frontdoor | `azurerm_cdn_frontdoor_endpoint` | endpoint-panos-app | 1 |
| frontdoor | `azurerm_cdn_frontdoor_origin_group` | og-external-lb | 1 |
| frontdoor | `azurerm_cdn_frontdoor_origin` | origin-external-lb | 1 |
| frontdoor | `azurerm_cdn_frontdoor_route` | route-http | 1 |
| routing | `azurerm_route_table` | rt-spoke1-workload, rt-spoke2-workload | 2 |
| routing | `azurerm_route` | default→fw + spoke2→fw (Spoke1), default→fw + spoke1→fw (Spoke2) | 4 |
| routing | `azurerm_subnet_route_table_association` | – | 2 |
| spoke1_app | `azurerm_network_interface` | nic-spoke1-apache | 1 |
| spoke1_app | `azurerm_linux_virtual_machine` | vm-spoke1-apache (Ubuntu 22.04, Apache2) | 1 |
| spoke2_dc | `azurerm_network_interface` | nic-spoke2-dc | 1 |
| spoke2_dc | `azurerm_windows_virtual_machine` | vm-spoke2-dc (WS 2022) | 1 |
| spoke2_dc | `azurerm_virtual_machine_extension` | promote-to-dc (count=0 gdy skip_auto_promote=true) | 0–1 |
| spoke2_dc | `azurerm_public_ip` | pip-bastion-spoke2 | 1 |
| spoke2_dc | `azurerm_bastion_host` | bastion-spoke2 (Standard SKU) | 1 |

</details>

---

## 📁 Struktura plików

```
azure-transit-vnet-ha/
├── providers.tf                    # Terraform + azurerm (hub/spoke1/spoke2) + null provider
├── variables.tf                    # Globalne zmienne wejściowe
├── main.tf                         # Root module – wywołania modułów
├── outputs.tf                      # Wyjścia (IPs, hostnames, itd.)
├── terraform.tfvars                # ⚠️ WYPEŁNIJ PRZED DEPLOY (NIE commituj do git!)
├── terraform.tfvars.example        # Szablon tfvars – bezpieczny do commitowania
├── .gitignore                      # Wyklucza terraform.tfvars, .terraform/, tfstate
├── README.md                       # Ten plik
├── scripts/
│   ├── fix-drift.sh                # Naprawa state drift (terraform import)
│   └── check-panorama.sh          # Skrypt czekający na gotowość Panoramy
└── modules/
    ├── networking/                 # VNety, subnety, NSG, peering, Public IPs
    ├── panorama/                   # VM Panorama, 256 GB OS, 2TB data disk
    ├── bootstrap/                  # Storage Account, Managed Identity, bootstrap blobs
    ├── firewall/                   # 2x VM-Series HA, Availability Set
    ├── loadbalancer/               # External LB (TCP 80/443) + Internal LB (HA Ports)
    ├── frontdoor/                  # Azure Front Door Premium
    ├── routing/                    # UDR Route Tables
    ├── spoke1_app/                 # Ubuntu VM + Apache2 Hello World
    ├── spoke2_dc/                  # Windows Server 2022 DC + Azure Bastion
    └── panorama_config/            # panos provider: Template, DG, Zones, NAT, Security

phase2-panorama-config/             # OSOBNY katalog dla Phase 2 (panos provider)
├── providers.tf                    # panos provider konfiguracja
├── variables.tf
├── main.tf
├── outputs.tf
└── terraform.tfvars.example
```

---

## 📚 Źródła

- [Palo Alto Networks: Azure Transit VNet Deployment Guide](https://www.paloaltonetworks.com/apps/pan/public/downloadResource?pagePath=/content/pan/en_US/resources/guides/azure-transit-vnet-deployment-guide)
- [VM-Series Bootstrap on Azure](https://docs.paloaltonetworks.com/vm-series/11-1/vm-series-deployment/bootstrap-the-vm-series-firewall/bootstrap-the-vm-series-firewall-in-azure)
- [Azure Standard Load Balancer](https://docs.microsoft.com/azure/load-balancer/)
- [Azure Front Door Premium](https://docs.microsoft.com/azure/frontdoor/)
- [Terraform panos Provider](https://registry.terraform.io/providers/PaloAltoNetworks/panos/latest/docs)
- [Terraform azurerm Provider](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs)

---

## 📄 Licencja

Projekt dostępny na licencji MIT. Szczegóły w pliku [LICENSE](LICENSE).

---

*Azure Transit VNet – VM-Series Active/Passive HA Reference Architecture*
*Palo Alto Networks | Terraform | Azure*
