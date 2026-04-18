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
5. [WAŻNE: Kolejność faz wdrożenia](#-ważne-kolejność-faz-wdrożenia)
6. [Phase 1a – Sieć + Panorama + DC/Bastion](#-phase-1a--sieć--panorama--dcbastion)
7. [Phase 2 – Konfiguracja Panoramy (PRZED FW!)](#-phase-2--konfiguracja-panoramy-przed-fw)
8. [Phase 1b – Bootstrap + Firewalle + Reszta](#-phase-1b--bootstrap--firewalle--reszta)
9. [Dostęp przez Spoke2 Bastion](#-dostęp-przez-spoke2-bastion)
10. [Weryfikacja po wdrożeniu](#-weryfikacja-po-wdrożeniu)
11. [Rozwiązywanie problemów](#-rozwiązywanie-problemów)
12. [Bezpieczeństwo](#-bezpieczeństwo)
13. [Destroy – usuwanie infrastruktury](#-destroy--usuwanie-infrastruktury)

---

## 🏗 Architektura

```
                    Internet
                        │
                        ▼
              ┌──────────────────┐
              │  Azure Front Door │  (global anycast, Premium)
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
│  snet-untrust 10.0.1.0/24    snet-trust 10.0.2.0/24 │
│  External LB pip-external-lb  Internal LB 10.0.2.100 │
│  FW1-eth1 10.0.1.4            FW1-eth2 10.0.2.4     │
│  FW2-eth1 10.0.1.5            FW2-eth2 10.0.2.5     │
│                                                      │
│  snet-ha 10.0.3.0/24                                 │
│  FW1-HA2 10.0.3.4 ──HA2── FW2-HA2 10.0.3.5         │
└───────────────────────┬──────────────────────────────┘
                VNet Peering (bidirectional)
        ┌───────────────┴──────────────────┐
        │                                  │
┌───────▼──────────────┐    ┌──────────────▼────────────────────┐
│  Spoke1  10.1.0.0/16 │    │  Spoke2  10.2.0.0/16              │
│  UDR→10.0.2.100      │    │  UDR→10.0.2.100                   │
│  vm-spoke1-apache    │    │  vm-spoke2-dc  10.2.0.4  (DC/RDP) │
│    10.1.0.4          │    │  AzureBastionSubnet 10.2.255.192  │
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
| **Admin SSH/RDP** | Admin → pip-bastion-spoke2 → Spoke2 Bastion → FW/Panorama/DC | – |
| **FW/Panorama outbound mgmt** | eth0 → NAT Gateway (pip-nat-gateway-mgmt) → Internet | – |

---

## 🔒 Model dostępu administracyjnego

**Jeden Bastion (Spoke2), zero publicznych IP na VM zarządzania.**

```
Admin (laptop)
  └── pip-bastion-spoke2  ← jedyny publiczny IP dla zarządzania
        └── bastion-spoke2 (Standard SKU)
              ├── IpConnect --target-ip-address (porty 22 i 3389):
              │   ├── SSH → FW1 (10.0.0.4)      ← Hub przez VNet peering
              │   ├── SSH → FW2 (10.0.0.5)      ← Hub przez VNet peering
              │   ├── SSH → Panorama (10.0.0.10) ← Hub przez VNet peering
              │   └── RDP → DC (10.2.0.4)        ← Spoke2 lokalnie
              └── Tunneling --target-resource-id (dowolny port):
                  └── HTTPS → Panorama:443      ← Phase 2 panos provider

DC (10.2.0.4) → VNet peering → Hub VNet:
  Chrome → https://10.0.0.10  (Panorama GUI)
  Chrome → https://10.0.0.4   (FW1 GUI)
  Chrome → https://10.0.0.5   (FW2 GUI)
```

| Zasób | Pub. IP | Dostęp |
|-------|:---:|--------|
| vm-panorama (10.0.0.10) | ❌ | Bastion SSH / RDP DC → Chrome |
| vm-panos-fw1 (10.0.0.4) | ❌ | Bastion SSH / RDP DC → Chrome |
| vm-panos-fw2 (10.0.0.5) | ❌ | Bastion SSH / RDP DC → Chrome |
| vm-spoke2-dc (10.2.0.4) | ❌ | Bastion IpConnect RDP |
| pip-bastion-spoke2 | ✅ | Spoke2 Bastion – jedyny punkt wejścia |
| pip-external-lb | ✅ | Ruch aplikacyjny przez FW |
| pip-nat-gateway-mgmt | ✅ | Outbound snet-mgmt (TCP/UDP/ICMP) – tylko wychodzący |

### Internet z Panoramy/FW – NAT Gateway

NAT Gateway (`natgw-mgmt` + `pip-nat-gateway-mgmt`) zapewnia wychodzący dostęp do Internetu dla `snet-mgmt`. Obsługuje **TCP, UDP i ICMP** – ping do zewnętrznych adresów powinien działać.

NSG `snet-mgmt` ma jawną regułę `Allow-All-Outbound-Internet` (priorytet 200) która gwarantuje przepuszczenie całego ruchu wychodzącego niezależnie od potencjalnych Azure Policy.

> **Test internetu z Panoramy:**
> ```
> # SSH do Panoramy przez Bastion:
> az network bastion ssh --name bastion-spoke2 --resource-group rg-spoke2-dc \
>   --target-ip-address 10.0.0.10 --auth-type password --username panadmin
>
> # PAN-OS CLI – testy:
> > ping host 8.8.8.8 count 3          ← ICMP – powien działać
> > request system software info        ← TCP do Palo Alto servers
> ```

---

## ✅ Wymagania wstępne

```bash
# Zainstaluj rozszerzenie Bastion (jednorazowo)
az extension add --name bastion
az login
az account set --subscription "<hub_subscription_id>"
```

**Licencje BYOL** (z [Palo Alto CSP Portal](https://support.paloaltonetworks.com/)):
- 2× VM-Series BYOL auth code (np. `D5541146`) → `fw_auth_code`
- 1× Panorama BYOL auth code (np. `F3862013`) → `panorama_auth_code`

---

## ⚙️ Konfiguracja zmiennych

```bash
cp terraform.tfvars.example terraform.tfvars
```

```hcl
# Subskrypcje
hub_subscription_id    = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
spoke1_subscription_id = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
spoke2_subscription_id = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

# Hasła
admin_username    = "panadmin"
admin_password    = "Str0ng!Password2024"    # min 12 znaków

dc_admin_username = "dcadmin"
dc_admin_password = "DC-Str0ng!2024"

# Licencje BYOL (z Palo Alto CSP Portal)
fw_auth_code       = "D5541146"              # przykład – wstaw własny
panorama_auth_code = "F3862013"              # przykład – wstaw własny

# Twój publiczny IP (dla Storage Account network_rules)
terraform_operator_ips = ["X.X.X.X"]        # curl -s https://api.ipify.org

# Nazwy DG i Template Stack (MUSZĄ zgadzać się z Phase 2!)
panorama_device_group   = "Transit-VNet-DG"
panorama_template_stack = "Transit-VNet-Stack"

# Uzupełnij po Phase 1a (po wygenerowaniu klucza w Panoramie)
panorama_vm_auth_key = ""
```

---

## ⚡ WAŻNE: Kolejność faz wdrożenia

```
Phase 1a → Phase 2 → Phase 1b
    │           │         │
    │           │         └── FW bootstrap z DG/Template → FW rejestruje się w Panoramie
    │           └── Tworzy DG i Template Stack w Panoramie (WYMAGANE przed FW!)
    └── Panorama + DC/Bastion (bez FW)
```

**Dlaczego Phase 2 PRZED Phase 1b?**
FW podczas startu czyta init-cfg i rejestruje się w Panoramie wskazując konkretny
`Device Group` i `Template Stack`. Te obiekty MUSZĄ istnieć w Panoramie w momencie
rejestracji FW. Phase 2 (panos provider) tworzy je automatycznie.

---

## 🚀 Phase 1a – Sieć + Panorama + DC/Bastion

> **CEL**: Hub VNet, Spoke2 z Bastionem i DC, Panorama. Bez FW na tym etapie.

### Krok 1 – Init i walidacja

```bash
terraform init
terraform validate && echo "OK"
```

### Krok 2 – Wdróż infrastrukturę Phase 1a

```bash
terraform apply \
  -target=azurerm_resource_group.hub \
  -target=azurerm_resource_group.spoke1 \
  -target=azurerm_resource_group.spoke2 \
  -target=module.networking \
  -target=module.panorama \
  -target=module.spoke2_dc
```

> ⏱ ~15-20 min. Tworzy: Hub VNet, NAT Gateway, Spoke VNety, DC (Windows Server 2022 + AD DS), Spoke2 Bastion, Panorama VM.

### Krok 3 – Poczekaj na Panoramę i sprawdź dostęp

```bash
chmod +x scripts/check-panorama.sh
./scripts/check-panorama.sh
```

Skrypt czeka na `VM running`, pokazuje komendy dostępu i otwiera RDP tunnel do DC (`localhost:33389`).

**W NOWYM terminalu – RDP do DC:**
```bash
# Windows:
mstsc /v:localhost:33389
# macOS: Microsoft Remote Desktop → Add PC → localhost:33389
```
Login: `dcadmin` | Hasło: `dc_admin_password`

### Krok 4 – Sprawdź Panoramę przez DC

Na DC, Chrome:
```
https://10.0.0.10
ADVANCED → Proceed to 10.0.0.10 (unsafe)   ← certyfikat self-signed
Login: panadmin | Hasło: admin_password
```

### Krok 5 – Aktywacja licencji Panoramy

Panorama powinna aktywować się automatycznie przy starcie (init-cfg zawiera `authcodes`).
Jeśli nie – aktywuj ręcznie przez GUI:

```
Panorama → Licenses → Activate feature using auth code
→ Wpisz panorama_auth_code (np. F3862013) → Submit
```

> ℹ️ Licencja wymaga połączenia TCP 443 → `updates.paloaltonetworks.com`
> Połączenie idzie przez NAT Gateway (TCP, UDP, ICMP obsługiwane).
> Jeśli aktywacja się nie powiedzie, sprawdź sekcję [Rozwiązywanie problemów](#-rozwiązywanie-problemów).

### Krok 6 – Pobierz external_lb_public_ip (potrzebne w Phase 2)

```bash
terraform output -raw external_lb_public_ip
# Zanotuj ten IP – będzie potrzebny w Phase 2 terraform.tfvars
```

---

## 🔧 Phase 2 – Konfiguracja Panoramy (PRZED FW!)

> ⚠️ **Phase 2 MUSI być wykonana PRZED Phase 1b (FW)!**
> Tworzy Device Group i Template Stack w Panoramie.
> FW podczas startu szuka tych obiektów – jeśli nie istnieją, rejestracja FW się nie powiedzie.

### Krok 1 – Terminal 1: Uruchom tunel HTTPS do Panoramy (pozostaw otwarty)

```bash
PANORAMA_ID=$(terraform output -raw panorama_vm_id)
az network bastion tunnel --name bastion-spoke2 --resource-group rg-spoke2-dc --target-resource-id "$PANORAMA_ID" --resource-port 443 --port 44300
```

> `--target-resource-id` wymagane dla portu 443.
> IpConnect (`--target-ip-address`) obsługuje tylko porty 22 i 3389.

### Krok 2 – Terminal 2: Przygotuj terraform.tfvars dla Phase 2

```bash
cd phase2-panorama-config
cp terraform.tfvars.example terraform.tfvars
```

Edytuj `terraform.tfvars` – uzupełnij TYLKO dwa pola:

```hcl
# panorama_hostname ZAWSZE "127.0.0.1" (przez Bastion tunnel)
panorama_hostname = "127.0.0.1"
panorama_port     = 44300

# To samo co admin_password w Phase 1 terraform.tfvars
panorama_password = "Str0ng!Password2024"

# Pobrane w Phase 1a Krok 6:
external_lb_public_ip = "X.X.X.X"
```

Pozostałe wartości mają sensowne domyślne – nie zmieniaj bez potrzeby.

### Krok 3 – Deploy Phase 2

```bash
terraform init
terraform apply
```

Phase 2 tworzy w Panoramie:
- ✅ Template (`Transit-VNet-Template`)
- ✅ Template Stack (`Transit-VNet-Stack`)
- ✅ Device Group (`Transit-VNet-DG`)
- ✅ Interfejsy ethernet1/1 (untrust), ethernet1/2 (trust), ethernet1/3 (HA2)
- ✅ Strefy untrust, trust
- ✅ Virtual Router + trasy statyczne
- ✅ NAT rules (DNAT HTTP/HTTPS → Apache, SNAT outbound)
- ✅ Security policies (Allow web, East-West, Outbound, Deny-All)

---

## 🚀 Phase 1b – Bootstrap + Firewalle + Reszta

> **CEL**: FW startują z bootstrap (init-cfg z panorama_vm_auth_key, DG, Template Stack)
> i automatycznie rejestrują się w Panoramie w Device Group i Template Stack z Phase 2.

### Krok 1 – Wygeneruj Device Registration Auth Key w Panoramie

Przez DC, Chrome → `https://10.0.0.10`:

```
Panorama → Device Registration Auth Key → Generate
Ważność: 8760 hours (1 rok)
→ SKOPIUJ klucz (wygląda np. tak: 2:BKLVoIq7Ty2GZqT1JcNI8aAIRHUH...)
```

> ⚠️ To jest **Device Registration Auth Key**, NIE auth code do licencji.
> Auth code (np. D5541146) używany jest do aktywacji licencji FW przez bootstrap/authcodes.

### Krok 2 – Zaktualizuj terraform.tfvars

```hcl
panorama_vm_auth_key = "2:BKLVoIq7Ty2GZqT1JcNI8a..."
```

### Krok 3 – Bootstrap (init-cfg z vm-auth-key, DG, Template Stack)

```bash
cd ..   # wróć do katalogu głównego
terraform apply -target=module.bootstrap
```

Bootstrap tworzy w Storage Account:
- `fw1/config/init-cfg.txt` – z panorama_vm_auth_key, tplname, dgname
- `fw1/license/authcodes` – `fw_auth_code` (auto-aktywacja licencji FW przy starcie)
- Analogicznie dla FW2

### Krok 4 – Wdróż FW i resztę infrastruktury

```bash
terraform apply \
  -target=module.loadbalancer \
  -target=module.firewall \
  -target=module.routing \
  -target=module.frontdoor \
  -target=module.spoke1_app
```

> ⏱ ~20-30 min. FW startuje, czyta bootstrap ze Storage Account przez Managed Identity,
> rejestruje się w Panoramie (DG: `Transit-VNet-DG`, Template: `Transit-VNet-Stack`),
> aktywuje licencję przez NAT Gateway.

### Krok 5 – Sprawdź rejestrację FW w Panoramie

DC → Chrome → `https://10.0.0.10`:
```
Panorama → Managed Devices → Summary
Oczekiwane: FW1 i FW2 – Connected ✅, In Sync ✅
```

> Może potrwać 5-15 min po deploy. FW musi pobrać bootstrap, zabootować PAN-OS,
> nawiązać połączenie z Panoramą przez snet-mgmt (prywatne IP).

### Krok 6 – Commit i Push polityki w Panoramie

```
DC → Chrome → https://10.0.0.10
Panorama → Commit → Commit and Push → Push to Devices
→ Wybierz FW1 i FW2 → Push Now
→ Poczekaj na: Push Success
```

---

## 🔐 Dostęp przez Spoke2 Bastion

`bastion-spoke2` to **jedyny punkt dostępu** do całego środowiska.
Obsługuje Spoke2 (DC) i Hub VNet (FW, Panorama) przez VNet peering.

### SSH do FW i Panoramy

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
# Terminal 1 (blokujący – otwiera RDP tunnel):
./scripts/check-panorama.sh
# LUB ręcznie:
az network bastion tunnel --name bastion-spoke2 --resource-group rg-spoke2-dc --target-ip-address 10.2.0.4 --resource-port 3389 --port 33389

# Terminal 2 (RDP):
mstsc /v:localhost:33389    # Windows
# macOS: Microsoft Remote Desktop → Add PC → localhost:33389
```

Na DC, Chrome: `https://10.0.0.10` (Panorama) | `https://10.0.0.4` (FW1) | `https://10.0.0.5` (FW2)

### Phase 2 – Tunel HTTPS do Panoramy (port 443)

```bash
PANORAMA_ID=$(terraform output -raw panorama_vm_id)
az network bastion tunnel --name bastion-spoke2 --resource-group rg-spoke2-dc --target-resource-id "$PANORAMA_ID" --resource-port 443 --port 44300
```

---

## 🔍 Weryfikacja po wdrożeniu

### Test 1 – Azure Front Door

```bash
AFD=$(terraform output -raw frontdoor_endpoint_hostname)
curl -s "https://$AFD" | grep -i "hello" && echo "AFD OK"
```

### Test 2 – External LB

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

### Test 4 – Internet z Panoramy

```bash
az network bastion ssh --name bastion-spoke2 --resource-group rg-spoke2-dc \
  --target-ip-address 10.0.0.10 --auth-type password --username panadmin
# W PAN-OS CLI:
# > ping host 8.8.8.8 count 3            ← ICMP – powinien działać przez NAT Gateway
# > request system software info         ← TCP do Palo Alto update servers
# > show system info | match serial      ← serial number (pojawia się po aktywacji)
```

### Test 5 – East-West przez FW

```bash
az network bastion ssh --name bastion-spoke2 --resource-group rg-spoke2-dc --target-ip-address 10.0.0.4 --auth-type password --username panadmin
# > ping source 10.0.2.4 host 10.2.0.4    ← Spoke1→Spoke2 przez FW trust interface
```

---

## 🔧 Rozwiązywanie problemów

### Ping z Panoramy/FW do internetu nie działa

NAT Gateway obsługuje TCP, UDP i ICMP. Jeśli ping nie działa, sprawdź:

```bash
# 1. Czy NAT Gateway jest wdrożony i powiązany z snet-mgmt?
az network nat-gateway show -g rg-transit-hub -n natgw-mgmt \
  --query '{state:provisioningState, subnets:subnets}' -o json

# 2. Czy Public IP NAT Gateway jest przypisany?
az network nat-gateway show -g rg-transit-hub -n natgw-mgmt \
  --query 'publicIpAddresses[0].id' -o tsv

# 3. Czy NSG snet-mgmt ma regułę Allow-All-Outbound-Internet?
az network nsg rule show -g rg-transit-hub \
  --nsg-name nsg-mgmt --name Allow-All-Outbound-Internet --query access
# Oczekiwane: "Allow"

# 4. Effective routes dla Panoramy
az network nic show-effective-route-table \
  --resource-group rg-transit-hub --name nic-panorama-mgmt -o table
# Oczekiwane: 0.0.0.0/0 → NextHopType=Internet (przez NAT Gateway)
```

Jeśli NAT Gateway ma `provisioningState: Succeeded` ale internet nie działa, spróbuj:
```bash
# Zrestart Panoramy (ponowne pobranie DHCP i default gateway)
az vm restart -g rg-transit-hub -n vm-panorama --no-wait
```

### Panorama nie aktywowana

1. Sprawdź czy `panorama_auth_code` w terraform.tfvars jest poprawny (format: `F3862013`)
2. Sprawdź logs init-cfg: `show system logs follow` w PAN-OS CLI
3. Ręczna aktywacja przez GUI (TCP 443 przez NAT Gateway działa):
   `Panorama → Licenses → Activate feature using auth code`
4. Jeśli TCP 443 nie działa: sprawdź czy NAT Gateway jest wdrożony:
   ```bash
   az network nat-gateway show -g rg-transit-hub -n natgw-mgmt --query "provisioningState"
   ```

### FW nie rejestruje się w Panoramie (brak w Managed Devices)

**Najczęstsza przyczyna**: Phase 2 nie była wykonana przed Phase 1b (FW).
Device Group lub Template Stack nie istniały gdy FW się bootstrapował.

**Rozwiązanie**:
1. Upewnij się że Phase 2 jest wdrożona (`cd phase2-panorama-config && terraform apply`)
2. Zrestartuj FW (FW ponownie czyta bootstrap i próbuje rejestracji):
   ```bash
   az vm restart -g rg-transit-hub -n vm-panos-fw1
   az vm restart -g rg-transit-hub -n vm-panos-fw2
   ```
3. Sprawdź logs w Panoramie: `Monitor → System` (filtruj: `subtype eq registration`)

### Phase 2 – "connection refused 127.0.0.1:44300"

Bastion tunnel MUSI być aktywny. Sprawdź czy terminal z `az network bastion tunnel` jest otwarty.

### Phase 2 – brakuje terraform init

```bash
cd phase2-panorama-config
terraform init    # ← wymagane przy pierwszym uruchomieniu lub po zmianie providers
terraform apply
```

### Storage Account 403

```bash
curl -s https://api.ipify.org
# Dodaj: terraform_operator_ips = ["NOWY.IP"] w terraform.tfvars
terraform apply -target=module.bootstrap
```

### State drift – "already exists"

```bash
chmod +x scripts/fix-drift.sh && ./scripts/fix-drift.sh
terraform apply
```

---

## 🔐 Bezpieczeństwo

- ✅ **Brak publicznych IP** na VM zarządzania (Panorama, FW1, FW2, DC)
- ✅ **Jeden Bastion** (Spoke2) – minimalna powierzchnia ataku
- ✅ **NAT Gateway** – kontrolowany outbound TCP/UDP z snet-mgmt (licencje, updates)
- ✅ **NSG snet-mgmt** – SSH/HTTPS tylko z Spoke2 VNet (10.2.0.0/16)
- ✅ **Storage Account** – `network_rules default_action=Deny`, Managed Identity
- ✅ **FW↔Panorama** – komunikacja prywatna (10.0.0.x)

---

## 📁 Struktura projektu

```
azure-transit-vnet-ha/
├── providers.tf / variables.tf / main.tf / outputs.tf
├── terraform.tfvars                # NIE commituj!
├── terraform.tfvars.example
├── scripts/
│   ├── check-panorama.sh           # Czeka na Panoramę + RDP tunnel do DC
│   └── fix-drift.sh
├── modules/
│   ├── networking/                 # Hub VNet, Spoke VNety, NSG, NAT GW, peering
│   ├── panorama/                   # VM Panorama (prywatne IP + init-cfg authcodes)
│   ├── bootstrap/                  # Storage Account + init-cfg blobs + authcodes
│   ├── firewall/                   # 2× VM-Series HA (prywatne IP)
│   ├── loadbalancer/               # External LB + Internal LB (HA Ports)
│   ├── frontdoor/                  # Azure Front Door Premium
│   ├── routing/                    # UDR Spoke1 + Spoke2
│   ├── spoke1_app/                 # Ubuntu + Apache2
│   ├── spoke2_dc/                  # Windows DC + Spoke2 Bastion (JEDYNY BASTION)
│   └── panorama_config/            # panos provider resources (DG, Template, policy)
└── phase2-panorama-config/         # OSOBNY root module – Phase 2
    ├── providers.tf                # panos provider (127.0.0.1:44300 przez Bastion)
    ├── variables.tf / main.tf / outputs.tf
    └── terraform.tfvars.example    # panorama_hostname="127.0.0.1", port=44300
```

---

## 🚨 Destroy – usuwanie infrastruktury

```bash
# Terraform destroy
terraform destroy -auto-approve 2>&1 | tee destroy.log

# Azure CLI (gdy state uszkodzony)
az group delete --name rg-transit-hub --yes --no-wait
az group delete --name rg-spoke1-app  --yes --no-wait
az group delete --name rg-spoke2-dc   --yes --no-wait
```

---

## 📚 Źródła

- [PAN Azure Transit VNet Deployment Guide](https://www.paloaltonetworks.com/apps/pan/public/downloadResource?pagePath=/content/pan/en_US/resources/guides/azure-transit-vnet-deployment-guide)
- [VM-Series Bootstrap on Azure](https://docs.paloaltonetworks.com/vm-series/11-1/vm-series-deployment/bootstrap-the-vm-series-firewall/bootstrap-the-vm-series-firewall-in-azure)
- [Azure Bastion Native Client](https://learn.microsoft.com/azure/bastion/native-client)
- [Azure NAT Gateway FAQ](https://learn.microsoft.com/azure/nat-gateway/faq)
- [Terraform panos Provider](https://registry.terraform.io/providers/PaloAltoNetworks/panos/latest/docs)

---

*Azure Transit VNet – VM-Series Active/Passive HA | Palo Alto Networks | Terraform | Azure*
