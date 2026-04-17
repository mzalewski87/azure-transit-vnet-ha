# 🔥 Azure Transit VNet – Palo Alto VM-Series HA

> **Kompletna infrastruktura jako kod (IaaC) dla referencyjnej architektury Palo Alto Networks na Azure**

[![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.5-7B42BC?logo=terraform)](https://www.terraform.io/)
[![PAN-OS](https://img.shields.io/badge/PAN--OS-latest%20BYOL-E31837?logo=paloaltonetworks)](https://www.paloaltonetworks.com/)
[![Azure](https://img.shields.io/badge/Azure-West%20Europe-0078D4?logo=microsoftazure)](https://azure.microsoft.com/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Implementacja referencyjna oparta na: **[PAN Azure Transit VNet Deployment Guide](https://www.paloaltonetworks.com/apps/pan/public/downloadResource?pagePath=/content/pan/en_US/resources/guides/azure-transit-vnet-deployment-guide)**

---

## 📋 Spis treści

1. [Architektura](#-architektura)
2. [Model dostępu administracyjnego](#-model-dostępu-administracyjnego)
3. [Wymagania wstępne](#-wymagania-wstępne)
4. [Konfiguracja zmiennych](#-konfiguracja-zmiennych)
5. [Phase 1a – Sieć + Panorama + DC](#-phase-1a--sieć--panorama--dc)
6. [Phase 1b – Bootstrap + Firewalle + Reszta](#-phase-1b--bootstrap--firewalle--reszta)
7. [Phase 2 – Konfiguracja Panoramy przez panos provider](#-phase-2--konfiguracja-panoramy-przez-panos-provider)
8. [Dostęp przez Spoke2 Bastion](#-dostęp-przez-spoke2-bastion)
9. [Weryfikacja po wdrożeniu](#-weryfikacja-po-wdrożeniu)
10. [Rozwiązywanie problemów](#-rozwiązywanie-problemów)
11. [Bezpieczeństwo](#-bezpieczeństwo)
12. [Destroy – usuwanie infrastruktury](#-destroy--usuwanie-infrastruktury)

---

## 🏗 Architektura

```
                    Internet
                        │
                        ▼
              ┌──────────────────┐
              │  Azure Front Door │  (global anycast, Premium)
              │     Premium       │
              └────────┬─────────┘
                       │ HTTPS
                       ▼
┌──────────────────────────────────────────────────────┐
│            Hub VNet  10.0.0.0/16                     │
│                                                      │
│  snet-mgmt 10.0.0.0/24  (BRAK publicznych IP!)       │
│  ┌────────────────────────────────────────────────┐  │
│  │  vm-panorama  10.0.0.10  ← NAT GW (outbound)   │  │
│  │  vm-panos-fw1 10.0.0.4   ← NAT GW (outbound)   │  │
│  │  vm-panos-fw2 10.0.0.5   ← NAT GW (outbound)   │  │
│  └────────────────────────────────────────────────┘  │
│                                                      │
│  snet-untrust 10.0.1.0/24                            │
│  ┌────────────────────────────────────────────────┐  │
│  │  FW1-eth1 10.0.1.4  FW2-eth1 10.0.1.5          │  │
│  │  External LB pip-external-lb ← AFD origin       │  │
│  └────────────────────────────────────────────────┘  │
│                                                      │
│  snet-trust 10.0.2.0/24                              │
│  ┌────────────────────────────────────────────────┐  │
│  │  FW1-eth2 10.0.2.4  FW2-eth2 10.0.2.5          │  │
│  │  Internal LB 10.0.2.100 ← UDR next-hop          │  │
│  └────────────────────────────────────────────────┘  │
│                                                      │
│  snet-ha 10.0.3.0/24                                 │
│  ┌────────────────────────────────────────────────┐  │
│  │  FW1-HA2 10.0.3.4 ──HA2──  FW2-HA2 10.0.3.5   │  │
│  └────────────────────────────────────────────────┘  │
└───────────────────────┬──────────────────────────────┘
                VNet Peering (bidirectional)
        ┌───────────────┴──────────────────┐
        │                                  │
┌───────▼──────────────┐    ┌──────────────▼────────────────────┐
│  Spoke1  10.1.0.0/16 │    │  Spoke2  10.2.0.0/16              │
│  UDR→10.0.2.100      │    │  UDR→10.0.2.100                   │
│  vm-spoke1-apache    │    │  vm-spoke2-dc  10.2.0.4           │
│    10.1.0.4 Apache2  │    │  AzureBastionSubnet 10.2.255.192  │
└──────────────────────┘    │  bastion-spoke2 ← JEDYNY BASTION  │
                            │  pip-bastion-spoke2 (public IP)   │
                            └───────────────────────────────────┘
```

### Przepływy ruchu

| Typ ruchu | Ścieżka | Inspekcja FW |
|-----------|---------|:---:|
| **Inbound HTTP/HTTPS** | Internet → AFD → Ext LB → FW (DNAT) → Apache 10.1.0.4 | ✅ |
| **Outbound Internet** | Spoke → UDR → Int LB → FW (SNAT) → Internet | ✅ |
| **East-West** | Spoke1 → UDR → Int LB → FW → Spoke2 | ✅ |
| **Admin SSH** | Admin → pip-bastion-spoke2 → Spoke2 Bastion → SSH FW/Panorama | – |
| **Admin GUI** | Admin → Bastion → RDP DC → Chrome → https://10.0.0.10 | – |
| **FW outbound mgmt** | FW eth0 → NAT Gateway → Internet (licencje, updates) | – |

---

## 🔒 Model dostępu administracyjnego

**Jeden Bastion, zero publicznych IP na VM zarządzania.**

```
Admin (laptop)
  └── pip-bastion-spoke2  ← jedyny publiczny IP dla zarządzania
        └── bastion-spoke2 (Standard SKU, ip_connect + tunneling)
              │
              ├── IpConnect (--target-ip-address, porty 22 i 3389):
              │   ├── SSH → FW1  (10.0.0.4)   [Hub przez VNet peering]
              │   ├── SSH → FW2  (10.0.0.5)   [Hub przez VNet peering]
              │   ├── SSH → Panorama (10.0.0.10) [Hub przez VNet peering]
              │   └── RDP → DC   (10.2.0.4)   [Spoke2 – lokalnie]
              │
              └── Tunneling (--target-resource-id, dowolny port):
                  └── HTTPS tunnel → Panorama:443 (Phase 2 panos provider)

DC (10.2.0.4) → VNet peering → Hub VNet:
  Chrome → https://10.0.0.10  (Panorama GUI)
  Chrome → https://10.0.0.4   (FW1 GUI)
  Chrome → https://10.0.0.5   (FW2 GUI)
```

| Zasób | Publiczny IP | Dostęp |
|-------|:---:|--------|
| vm-panorama (10.0.0.10) | ❌ | Spoke2 Bastion IpConnect SSH / RDP DC → Chrome |
| vm-panos-fw1 (10.0.0.4) | ❌ | Spoke2 Bastion IpConnect SSH / RDP DC → Chrome |
| vm-panos-fw2 (10.0.0.5) | ❌ | Spoke2 Bastion IpConnect SSH / RDP DC → Chrome |
| vm-spoke2-dc (10.2.0.4) | ❌ | Spoke2 Bastion IpConnect RDP |
| pip-bastion-spoke2 | ✅ | Spoke2 Bastion – jedyny punkt wejścia |
| pip-external-lb | ✅ | Ruch aplikacyjny przez FW |
| pip-nat-gateway-mgmt | ✅ | Outbound snet-mgmt (licencje, updates) – tylko wychodzący |

---

## ✅ Wymagania wstępne

| Narzędzie | Min. wersja |
|-----------|:-----------:|
| Terraform | ≥ 1.5.0 |
| Azure CLI | ≥ 2.60.0 |
| az bastion extension | – |

```bash
az extension add --name bastion
az login
az account set --subscription "<hub_subscription_id>"
```

**Licencje BYOL** (z [Palo Alto CSP Portal](https://support.paloaltonetworks.com/)):
- 2× VM-Series BYOL auth code → `fw_auth_code`
- 1× Panorama BYOL auth code → `panorama_auth_code`

---

## ⚙️ Konfiguracja zmiennych

```bash
cp terraform.tfvars.example terraform.tfvars
# Edytuj terraform.tfvars
```

```hcl
# Wymagane subskrypcje (mogą być ta sama lub różne)
hub_subscription_id    = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
spoke1_subscription_id = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
spoke2_subscription_id = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

# Hasła
admin_username    = "panadmin"
admin_password    = "Str0ng!Password2024"

dc_admin_username = "dcadmin"
dc_admin_password = "DC-Str0ng!2024"

# Licencje BYOL
fw_auth_code       = "I1234567-XXXX-XXXX"
panorama_auth_code = "P7654321-XXXX-XXXX"

# Twój publiczny IP (dla Storage Account network_rules)
terraform_operator_ips = ["X.X.X.X"]  # curl -s https://api.ipify.org

# Uzupełnij po Phase 1a (po wygenerowaniu klucza w Panoramie)
panorama_vm_auth_key = ""
```

---

## 🚀 Phase 1a – Sieć + Panorama + DC

> **CEL**: Hub VNet, Spoke2 z Bastionem i DC, Panorama.
> Następnie przez Bastion → DC → Panorama GUI → generujemy vm-auth-key.

### Krok 1 – Init i walidacja

```bash
terraform init
terraform validate && echo "OK"
```

### Krok 2 – Wdróż sieć, Panoramę i DC

```bash
terraform apply \
  -target=azurerm_resource_group.hub \
  -target=azurerm_resource_group.spoke1 \
  -target=azurerm_resource_group.spoke2 \
  -target=module.networking \
  -target=module.panorama \
  -target=module.spoke2_dc
```

> ⏱ ~15-20 min. Tworzy: Hub VNet, Spoke VNety, Bastion w Spoke2, DC (Windows Server 2022), Panorama VM, NAT Gateway.

### Krok 3 – Poczekaj na Panoramę i otwórz GUI przez DC

Użyj skryptu który czeka na Panoramę, potem otwiera RDP tunnel do DC:

```bash
chmod +x scripts/check-panorama.sh
./scripts/check-panorama.sh
```

Skrypt:
1. Czeka aż Panorama osiągnie stan `VM running`
2. Pokazuje wszystkie komendy dostępu (SSH, GUI, Phase 2 tunnel)
3. Otwiera **RDP tunnel do DC** na `localhost:33389`

**W NOWYM terminalu – RDP do DC:**

```bash
# Windows:
mstsc /v:localhost:33389

# macOS (Microsoft Remote Desktop):
# Add PC → localhost:33389
```

Login: `dcadmin` | Hasło: `dc_admin_password` z `terraform.tfvars`

### Krok 4 – Panorama GUI przez DC

Na DC otwórz przeglądarkę (Chrome/Edge):

```
https://10.0.0.10
```

- Kliknij **Advanced → Proceed to 10.0.0.10 (unsafe)** (certyfikat self-signed)
- Login: `panadmin` | Hasło: z `terraform.tfvars`

### Krok 5 – Aktywuj licencję i wygeneruj VM Auth Key

1. **Aktywuj licencję** (jeśli nie aktywowała się z init-cfg):
   `Panorama → Licenses → Activate feature using auth code`
   → wpisz `panorama_auth_code`

2. **Wygeneruj VM Auth Key**:
   `Panorama → Device Registration Auth Key → Generate`
   → Ważność: **8760 hours** → **SKOPIUJ klucz**

### Krok 6 – Wklej klucz do terraform.tfvars

```hcl
panorama_vm_auth_key = "SKOPIOWANY-KLUCZ-Z-PANORAMY"
```

---

## 🚀 Phase 1b – Bootstrap + Firewalle + Reszta

> **CEL**: FW startują z `vm-auth-key` w init-cfg i auto-rejestrują się w Panoramie.

### Krok 1 – Bootstrap (init-cfg z vm-auth-key)

```bash
terraform apply -target=module.bootstrap
```

### Krok 2 – Pełna infrastruktura

```bash
terraform apply \
  -target=module.loadbalancer \
  -target=module.firewall \
  -target=module.routing \
  -target=module.frontdoor \
  -target=module.spoke1_app
```

> ⏱ ~20-30 min (FW boot + rejestracja w Panoramie najwolniejsze)

### Krok 3 – Sprawdź outputs

```bash
terraform output
```

Kluczowe outputy:
```
spoke2_bastion_name    = "bastion-spoke2"
spoke2_bastion_public_ip = "X.X.X.X"   ← jedyny publiczny IP zarządzania
nat_gateway_public_ip  = "Y.Y.Y.Y"     ← outbound snet-mgmt
external_lb_public_ip  = "Z.Z.Z.Z"     ← ruch aplikacyjny
fw1_mgmt_private_ip    = "10.0.0.4"
fw2_mgmt_private_ip    = "10.0.0.5"
panorama_private_ip    = "10.0.0.10"
domain_controller_private_ip = "10.2.0.4"
frontdoor_endpoint_hostname  = "endpoint-xxx.z01.azurefd.net"
```

### Krok 4 – Zweryfikuj rejestrację FW w Panoramie

Przez DC (RDP tunnel skryptem `./scripts/check-panorama.sh`), potem Chrome na DC:

```
https://10.0.0.10
Panorama → Managed Devices → Summary
FW1 i FW2: Connected ✅, In Sync ✅
```

---

## 🔧 Phase 2 – Konfiguracja Panoramy przez panos provider

> Provider panos łączy się do Panoramy przez aktywny Bastion Tunnel.
> Tunel MUSI być aktywny w osobnym terminalu podczas `terraform apply`.

### Krok 1 – Terminal 1: uruchom tunel HTTPS (pozostaw otwarty)

```bash
PANORAMA_ID=$(terraform output -raw panorama_vm_id)
az network bastion tunnel --name bastion-spoke2 --resource-group rg-spoke2-dc --target-resource-id "$PANORAMA_ID" --resource-port 443 --port 44300
```

> `--target-resource-id` wymagane dla port 443. IpConnect (`--target-ip-address`) dozwala tylko 22 i 3389.

### Krok 2 – Terminal 2: deploy Phase 2

```bash
cd phase2-panorama-config
cp terraform.tfvars.example terraform.tfvars
```

```hcl
# phase2-panorama-config/terraform.tfvars
panorama_hostname = "127.0.0.1"
panorama_port     = 44300
panorama_username = "panadmin"
panorama_password = "haslo_z_terraform.tfvars"
external_lb_public_ip = "Z.Z.Z.Z"  # z terraform output
```

```bash
terraform init && terraform apply
```

### Krok 3 – Commit i Push w Panoramie

```
Na DC: Chrome → https://10.0.0.10
Panorama → Commit → Commit and Push → Push to Devices
Czekaj: Push Success na FW1 i FW2
```

---

## 🔐 Dostęp przez Spoke2 Bastion

Spoke2 Bastion (`bastion-spoke2`) to **jedyny punkt dostępu** do całego środowiska.
Obsługuje zarówno Spoke2 (DC) jak i Hub VNet (FW, Panorama) przez VNet peering.

### SSH do FW i Panoramy (PAN-OS CLI)

IpConnect (`--target-ip-address`) – działa przez VNet peering, porty 22 i 3389.

```bash
# SSH do FW1 (Active)
az network bastion ssh --name bastion-spoke2 --resource-group rg-spoke2-dc --target-ip-address 10.0.0.4 --auth-type password --username panadmin

# SSH do FW2 (Passive)
az network bastion ssh --name bastion-spoke2 --resource-group rg-spoke2-dc --target-ip-address 10.0.0.5 --auth-type password --username panadmin

# SSH do Panoramy
az network bastion ssh --name bastion-spoke2 --resource-group rg-spoke2-dc --target-ip-address 10.0.0.10 --auth-type password --username panadmin
```

### RDP do DC i GUI Panoramy/FW

```bash
# RDP tunnel do DC (Terminal 1 – blokujący):
./scripts/check-panorama.sh
# LUB ręcznie:
az network bastion tunnel --name bastion-spoke2 --resource-group rg-spoke2-dc --target-ip-address 10.2.0.4 --resource-port 3389 --port 33389

# RDP (Terminal 2):
mstsc /v:localhost:33389   # Windows
# macOS: Microsoft Remote Desktop → Add PC → localhost:33389
```

Na DC, Chrome:

| URL | Zasób |
|-----|-------|
| `https://10.0.0.10` | Panorama GUI |
| `https://10.0.0.4` | FW1 GUI (Active) |
| `https://10.0.0.5` | FW2 GUI (Passive) |

> Kliknij **Advanced → Proceed to ... (unsafe)** – certyfikat self-signed.

### Phase 2 – Tunel HTTPS do Panoramy

```bash
# Terminal 1 (pozostaw otwarty):
PANORAMA_ID=$(terraform output -raw panorama_vm_id)
az network bastion tunnel --name bastion-spoke2 --resource-group rg-spoke2-dc --target-resource-id "$PANORAMA_ID" --resource-port 443 --port 44300

# Terminal 2:
cd phase2-panorama-config && terraform apply
```

---

## 🔍 Weryfikacja po wdrożeniu

### Test 1 – Azure Front Door

```bash
AFD=$(terraform output -raw frontdoor_endpoint_hostname)
curl -s "https://$AFD" | grep -i "hello" && echo "AFD OK"
```

### Test 2 – External LB bezpośrednio

```bash
ELB=$(terraform output -raw external_lb_public_ip)
curl -s --connect-timeout 10 "http://$ELB" | grep -i "hello" && echo "Ext LB OK"
```

### Test 3 – Panorama Managed Devices

```
DC → Chrome → https://10.0.0.10
Panorama → Managed Devices → Summary
FW1: Connected, In Sync ✅
FW2: Connected, In Sync ✅
```

### Test 4 – East-West (SSH do FW, ping między Spoke)

```bash
az network bastion ssh --name bastion-spoke2 --resource-group rg-spoke2-dc --target-ip-address 10.0.0.4 --auth-type password --username panadmin
# W PAN-OS CLI:
# > ping host 10.2.0.4 source 10.0.2.4
```

### Test 5 – DC Active Directory

```
DC → Start → PowerShell:
Get-ADDomain | Select Name, DomainMode
# Oczekiwane: panw.labs
```

---

## 🔧 Rozwiązywanie problemów

### Storage Account 403

```bash
curl -s https://api.ipify.org  # sprawdź IP
# Dodaj do terraform.tfvars: terraform_operator_ips = ["NOWY.IP"]
terraform apply -target=module.bootstrap
```

### State drift – "already exists"

```bash
chmod +x scripts/fix-drift.sh && ./scripts/fix-drift.sh
terraform apply
```

### FW nie rejestruje się w Panoramie

1. Sprawdź czy `panorama_vm_auth_key` nie jest pusty
2. Zrestartuj FW:
   ```bash
   az vm restart -g rg-transit-hub -n vm-panos-fw1
   az vm restart -g rg-transit-hub -n vm-panos-fw2
   ```
3. Panorama → Monitor → System (logi rejestracji)

### DC extension timeout

```hcl
dc_skip_auto_promote = true  # jeśli extension już działa w tle
```

### Phase 2 – "connection refused 127.0.0.1:44300"

```
Tunel Bastion MUSI być aktywny w osobnym terminalu!
Sprawdź: az network bastion tunnel ... --port 44300
```

### Bastion – "Native client not enabled"

```bash
az network bastion show -g rg-spoke2-dc -n bastion-spoke2 --query "sku.name" -o tsv
# Musi zwrócić: Standard
```

---

## 🔐 Bezpieczeństwo

- ✅ **Brak publicznych IP** na VM zarządzania (Panorama, FW1, FW2, DC)
- ✅ **Jeden Bastion** (Spoke2) – minimalna powierzchnia ataku
- ✅ **NAT Gateway** – kontrolowany outbound z snet-mgmt
- ✅ **NSG snet-mgmt** – SSH/HTTPS tylko z Spoke2 VNet (10.2.0.0/16)
- ✅ **Storage Account** – `network_rules default_action=Deny`
- ✅ **FW↔Panorama** – komunikacja tylko prywatną siecią (10.0.0.x)

### Remote State (produkcja)

```hcl
backend "azurerm" {
  resource_group_name  = "rg-terraform-state"
  storage_account_name = "stterraformstate"
  container_name       = "tfstate"
  key                  = "transit-vnet-ha.tfstate"
}
```

---

## 📁 Struktura projektu

```
azure-transit-vnet-ha/
├── providers.tf                    # azurerm (hub/spoke1/spoke2)
├── variables.tf / outputs.tf       # zmienne i outputy root modułu
├── main.tf                         # root module
├── terraform.tfvars                # NIE commituj!
├── terraform.tfvars.example
├── scripts/
│   ├── check-panorama.sh           # Czeka na Panoramę + RDP tunnel do DC
│   └── fix-drift.sh                # Naprawa state drift
├── modules/
│   ├── networking/                 # Hub VNet, Spoke VNety, NSG, NAT GW, peering
│   ├── panorama/                   # VM Panorama (prywatne IP, NAT GW outbound)
│   ├── bootstrap/                  # Storage Account + init-cfg blobs
│   ├── firewall/                   # 2× VM-Series HA (prywatne IP)
│   ├── loadbalancer/               # External LB + Internal LB (HA Ports)
│   ├── frontdoor/                  # Azure Front Door Premium
│   ├── routing/                    # UDR Spoke1 + Spoke2
│   ├── spoke1_app/                 # Ubuntu + Apache2 (Hello World)
│   ├── spoke2_dc/                  # Windows DC + Spoke2 Bastion (JEDYNY BASTION)
│   └── panorama_config/            # panos provider resources
└── phase2-panorama-config/         # Osobny katalog Phase 2
    ├── providers.tf                # panos provider (przez Bastion tunnel)
    ├── variables.tf / main.tf / outputs.tf
    └── terraform.tfvars.example
```

---

## 🚨 Destroy – usuwanie infrastruktury

### Terraform destroy

```bash
terraform destroy -auto-approve 2>&1 | tee destroy.log
```

### Azure CLI (gdy state uszkodzony)

```bash
az group delete --name rg-transit-hub --yes --no-wait
az group delete --name rg-spoke1-app  --yes --no-wait
az group delete --name rg-spoke2-dc   --yes --no-wait
```

### Reset state po destroy

```bash
terraform state list | xargs -I {} terraform state rm {}
terraform init -reconfigure
```

---

## 📚 Źródła

- [PAN Azure Transit VNet Deployment Guide](https://www.paloaltonetworks.com/apps/pan/public/downloadResource?pagePath=/content/pan/en_US/resources/guides/azure-transit-vnet-deployment-guide)
- [VM-Series Bootstrap on Azure](https://docs.paloaltonetworks.com/vm-series/11-1/vm-series-deployment/bootstrap-the-vm-series-firewall/bootstrap-the-vm-series-firewall-in-azure)
- [Azure Bastion Native Client](https://learn.microsoft.com/azure/bastion/native-client)
- [az network bastion tunnel](https://learn.microsoft.com/cli/azure/network/bastion#az-network-bastion-tunnel)
- [Terraform panos Provider](https://registry.terraform.io/providers/PaloAltoNetworks/panos/latest/docs)

---

*Azure Transit VNet – VM-Series Active/Passive HA | Palo Alto Networks | Terraform | Azure*
