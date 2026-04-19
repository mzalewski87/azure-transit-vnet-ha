# Azure Transit VNet – VM-Series HA Reference Architecture

> Terraform IaaC dla referencyjnej architektury Palo Alto VM-Series HA w Azure.  
> 2x VM-Series (8 vCPU), Active/Passive HA, External + Internal LB, Azure Front Door,  
> VNet peering (Spoke1 + Spoke2), UDR, ruch east-west + inbound + outbound.

## Architektura

```
Internet
    │
    ▼
Azure Front Door (Premium)
    │  HTTP/HTTPS
    ▼
External Load Balancer (Public IP)
    │
    ▼
  ┌──────────────────────────────────────────┐
  │          Transit Hub VNet (10.0.0.0/16)   │
  │                                          │
  │  [FW1 Active]  ←─HA1─→  [FW2 Passive]   │
  │   eth0: mgmt              eth0: mgmt      │
  │   eth1/1: untrust         eth1/1: untrust │
  │   eth1/2: trust           eth1/2: trust   │
  │   eth1/3: HA2             eth1/3: HA2     │
  │                                          │
  └─────────────────┬────────────────────────┘
                    │
         Internal Load Balancer (10.0.2.100)
                    │
          ┌─────────┴────────┐
          │                  │
  VNet Peering           VNet Peering
   + UDR                  + UDR
          │                  │
  ┌───────┴──────┐   ┌───────┴──────┐
  │  Spoke1 App  │   │  Spoke2 DC   │
  │ 10.1.0.0/16  │   │ 10.2.0.0/16  │
  │ Apache VM    │   │ Windows DC   │
  └──────────────┘   └──────────────┘
                              │
                         Spoke2 Bastion
                      (dostęp do środowiska)
```

**Panorama** (`10.0.0.10`) zarządza obydwoma firewall'ami przez snet-mgmt.

---

## Wymagania wstępne

| Narzędzie | Minimalna wersja |
|-----------|-----------------|
| Terraform | >= 1.5.0 |
| Azure CLI (`az`) | >= 2.50 |
| `curl`, `bash` | dostępne w PATH |

```bash
# Zaloguj się do Azure
az login
az account set --subscription "<hub_subscription_id>"
```

### Licencje z Palo Alto CSP Portal

Przed rozpoczęciem potrzebujesz z [support.paloaltonetworks.com](https://support.paloaltonetworks.com):
- `fw_auth_code` → Assets → Auth Codes → VM-Series BYOL
- `panorama_auth_code` → Assets → Auth Codes → Panorama BYOL  
- `panorama_serial_number` → Assets → Devices → numer seryjny Panoramy

> **WAŻNE:** `panorama_serial_number` jest **wymagany** do automatycznej aktywacji  
> licencji Panoramy przy starcie. Bez niego licencja wymaga ręcznej aktywacji w GUI.

---

## Struktura projektu

```
.
├── main.tf                       # Root module – wywołuje wszystkie moduły
├── variables.tf                  # Zmienne wejściowe
├── outputs.tf                    # Outputy (IPs, resource IDs)
├── providers.tf                  # azurerm + random + time + null
├── terraform.tfvars.example      # Szablon konfiguracji – skopiuj do terraform.tfvars
│
├── modules/
│   ├── networking/               # VNet, subnety, NSG, NAT Gateway, peering, public IPs
│   ├── panorama/                 # VM Panorama (Standard_D16s_v3 / 64GB RAM)
│   ├── bootstrap/                # Storage Account + bootstrap package (init-cfg, authcodes)
│   ├── loadbalancer/             # External LB (Public) + Internal LB (Private)
│   ├── firewall/                 # 2x VM-Series (8 vCPU, Standard_D8s_v3) + NIC + AvSet
│   ├── routing/                  # UDR dla Spoke1 i Spoke2 → Internal LB
│   ├── frontdoor/                # Azure Front Door Premium
│   ├── spoke1_app/               # Apache VM w Spoke1
│   └── spoke2_dc/                # Windows Server DC w Spoke2 + Bastion
│
├── phase2-panorama-config/       # Konfiguracja Panoramy (panos Terraform provider)
│   ├── main.tf                   # Template Stack, Device Group, NAT, Security rules + auto-commit
│   ├── providers.tf              # panos + null provider
│   └── terraform.tfvars.example
│
├── optional/
│   └── dc-promote/               # Opcjonalna promocja DC do roli Domain Controller
│
└── scripts/
    ├── generate-vm-auth-key.sh   # Generuje VM Auth Key przez Panorama API
    ├── check-panorama.sh         # Sprawdza dostępność Panoramy
    └── fix-drift.sh              # Pomocniczy – naprawia drift konfiguracji
```

---

## Wdrożenie krok po kroku

### Przygotowanie

```bash
git clone https://github.com/mzalewski87/azure-transit-vnet-ha.git
cd azure-transit-vnet-ha

cp terraform.tfvars.example terraform.tfvars
```

Edytuj `terraform.tfvars` i uzupełnij **wszystkie** pola `REPLACE_ME`:

```hcl
# Subskrypcje Azure
hub_subscription_id    = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
spoke1_subscription_id = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"  # może być ten sam
spoke2_subscription_id = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"  # może być ten sam

# Hasła (min 12 znaków, wielkie/małe litery, cyfra, znak specjalny)
admin_password    = "PanAdmin@2024!"     # FW i Panorama
dc_admin_password = "DcAdmin@2024!"      # Windows DC

# Licencje z CSP Portal
fw_auth_code       = "XXXX-XXXX-XXXX-XXXX"
panorama_auth_code = "XXXX-XXXX-XXXX-XXXX"

# WYMAGANE: numer seryjny Panoramy z CSP Portal → Assets → Devices
panorama_serial_number = "007300014999"

# Twój publiczny IP (wymagany przez Azure Policy dla Storage Account)
# Pobierz: curl -s https://api.ipify.org
terraform_operator_ips = ["X.X.X.X"]
```

---

### Etap 1a – Sieć, Panorama, DC (Phase 1a)

```bash
terraform init

terraform apply \
  -target=azurerm_resource_group.hub \
  -target=azurerm_resource_group.spoke1 \
  -target=azurerm_resource_group.spoke2 \
  -target=module.networking \
  -target=module.bootstrap \
  -target=module.panorama \
  -target=module.spoke2_dc
```

⏱ **Czas:** ~15-20 min

> **Co się dzieje:**
> - Tworzone są VNety, subnety, NSG, NAT Gateway, VNet Peering
> - **Tworzony jest Bootstrap Storage Account** z plikami init-cfg dla Panoramy i FW
>   - SA jest wymagany PRZED Panoramą – Panorama czyta init-cfg z SA (nie z customData bezpośrednio)
>   - SA zawiera: `bootstrap/panorama/config/init-cfg.txt` (hostname, serial, authcodes)
>   - SA zawiera też: `bootstrap/fw1/config/init-cfg.txt` i `bootstrap/fw2/config/init-cfg.txt`
> - Wdrażana jest Panorama VM (Standard_D16s_v3 / 64 GB RAM)
>   - Panorama (jako PAN-OS) czyta `customData` → wskaźnik do SA → init-cfg z SA
>   - Panorama bootuje ~10-15 min; jeśli `panorama_serial_number` ustawiony → auto-aktywacja licencji
> - Wdrażany jest Windows DC w Spoke2 + Bastion

---

### Etap 2 – Konfiguracja Panoramy (Phase 2)

> **WARUNEK:** Panorama musi być uruchomiona i licencjonowana.

**Terminal 1 – otwórz tunel Bastion i zostaw go otwartym:**

```bash
PANORAMA_ID=$(terraform output -raw panorama_vm_id)

az network bastion tunnel \
  --name bastion-spoke2 \
  --resource-group rg-spoke2-dc \
  --target-resource-id "$PANORAMA_ID" \
  --resource-port 443 \
  --port 44300
```

> **Uwaga:** Wymagana jest opcja `--target-resource-id` (nie `--target-ip-address`).  
> IpConnect Azure Bastion obsługuje tylko porty 22 i 3389.  
> `--target-resource-id` umożliwia tunelowanie dowolnego portu (w tym 443).

**Terminal 2 – wdróż konfigurację Panoramy:**

```bash
cd phase2-panorama-config/
cp terraform.tfvars.example terraform.tfvars
```

Edytuj `phase2-panorama-config/terraform.tfvars`:

```hcl
panorama_password     = "PanAdmin@2024!"  # to samo co admin_password
external_lb_public_ip = "X.X.X.X"        # z: cd .. && terraform output -raw external_lb_public_ip
```

```bash
terraform init
terraform apply
```

> **Co się dzieje:**
> - Tworzony jest Template Stack i Device Group w Panoramie
> - Konfigurowane są interfejsy, strefy, routing, NAT rules, Security policies
> - Wykonywany jest automatyczny **commit** konfiguracji Panoramy
>   (Device Group i Template Stack muszą być w running config – nie wystarczy candidate config)

```bash
cd ..
```

---

### Generowanie VM Auth Key

> **WARUNEK:** Panorama musi być uruchomiona, licencjonowana i mieć zatwierdzoną konfigurację.  
> Tunel z Etapu 2 (Terminal 1) musi być aktywny.

```bash
chmod +x scripts/generate-vm-auth-key.sh
./scripts/generate-vm-auth-key.sh
```

Skrypt próbuje kilku formatów XML API (różne wersje Panoramy) i wyświetla raw response dla debugowania. Jeśli wszystkie formaty zawiodą:

**Ręczne generowanie w Panorama GUI:**
```
Zaloguj się przez Edge: https://127.0.0.1:44300 (tunel musi być aktywny)
→ Panorama → Devices → VM Auth Key → Generate → 1 hour
→ Skopiuj wygenerowany klucz
```

Wklej wynik do `terraform.tfvars`:
```hcl
panorama_vm_auth_key = "2:BKLVoIq7Ty2GZqT1JcNI8a..."
```

---

### Etap 1b – Bootstrap + Firewall + pozostałe zasoby (Phase 1b)

**Krok 1 – Aktualizacja Bootstrap z vm-auth-key:**

```bash
terraform apply -target=module.bootstrap
```

⏱ **Czas:** ~1-2 min (SA już istnieje z Phase 1a, aktualizacja blobów FW1/FW2 z vm-auth-key)

> **Co się dzieje:**
> - Aktualizuje blobs `fw1/config/init-cfg.txt` i `fw2/config/init-cfg.txt` z `panorama_vm_auth_key`
> - FW odczyta zaktualizowany init-cfg przy starcie za pomocą klucza SA (access-key)

**Krok 2 – Load Balancer, Firewall, Routing, Front Door, App:**

```bash
terraform apply \
  -target=module.loadbalancer \
  -target=module.firewall \
  -target=module.routing \
  -target=module.frontdoor \
  -target=module.spoke1_app
```

⏱ **Czas:** ~20-30 min (FW boot ~15 min)

---

### Weryfikacja – rejestracja FW w Panoramie

Poczekaj ~15-20 min od uruchomienia FW. Oczekiwany przepływ automatyczny:

```
FW boot → czyta init-cfg z SA (access-key) → znajdzie:
  - panorama-server=10.0.0.10
  - vm-auth-key=2:...
  - authcodes=...
  - timezone=Europe/Warsaw, NTP, DNS
↓
FW kontaktuje licensing.paloaltonetworks.com (przez NAT Gateway)
↓
Aktywacja licencji → serial number → Device Certificate (SC3)
↓
FW łączy z Panoramą: SC3 + vm-auth-key → rejestracja ✅
```

Sprawdź w Panorama GUI:
```
Tunel Bastion → https://127.0.0.1:44300 (Microsoft Edge)
→ Panorama → Managed Devices
→ FW1: Connected ✅  FW2: Connected ✅
```

**Push konfiguracji do FW:**
```
Panorama → Commit → Commit and Push → Push to All Devices → Push Now
```

---

### Opcjonalnie – Promocja Domain Controller

```bash
cd optional/dc-promote/
cp terraform.tfvars.example terraform.tfvars
# Ustaw: admin_password, dc_admin_password, hub/spoke2 subscription IDs
terraform init
terraform apply
```

⏱ **Czas:** ~30-45 min (Windows restartuje się podczas promocji)

---

## Rozwiązywanie problemów

### ⚠️ Panorama / FW: brak konfiguracji po boocie – user_data vs customData

**Przyczyna:** PAN-OS 10.x+ czyta konfigurację bootstrap z **Azure `userData`**, NIE z `customData`.  
Są to dwa odrębne pola w Azure API:

| Pole Azure | Terraform | Kto czyta | Uwaga |
|------------|-----------|-----------|-------|
| `osProfile.customData` | `custom_data` | PAN-OS < 10.x, cloud-init | Stary mechanizm |
| `userData` | `user_data` | PAN-OS 10.x, 11.x | **Nowy mechanizm** |

W Azure Portal przy tworzeniu VM widoczna jest zakładka **"User data"** – to właśnie `userData`.  
Jeśli init-cfg trafi do `customData` (nie `userData`), PAN-OS 11.x go zignoruje.

Ten projekt ustawia **oba pola** (`user_data` + `custom_data`) dla kompatybilności wstecznej.  
Jeśli Panorama lub FW nie mają konfiguracji po boocie, sprawdź czy `user_data` jest ustawione:
```bash
az vm show -g rg-transit-hub -n vm-panos-fw1 \
  --query 'storageProfile' -o json | grep -i userData
# lub sprawdź przez Azure Portal → VM → Configuration → User data
```

### generate-vm-auth-key.sh: komenda "unexpected" – brak licencji Panoramy

**Przyczyna:** Komenda `vm-auth-key generate` wymaga **aktywnej licencji Panoramy**.  
Jeśli init-cfg nie zadziałał (np. przez customData/userData issue), Panorama nie ma licencji  
i wszystkie próby generowania klucza kończą się błędem `code="17" is unexpected`.

**Diagnostyka:**
```bash
# Skrypt pokazuje teraz diagnostykę: wersję, hostname, serial i status licencji
./scripts/generate-vm-auth-key.sh
# Sprawdź linię: "Licencja Panoramy: ✅ aktywna" LUB ostrzeżenie o braku licencji
```

**Jeśli Panorama ma licencję** (✅) ale vm-auth-key ciągle "unexpected":
```
Edge → https://127.0.0.1:44300
→ Panorama → Devices → VM Auth Key → Generate → 1 hour  (PAN-OS 10.x)
  LUB
→ Panorama → Setup → Bootstrap → Generate VM Auth Key   (PAN-OS 11.x)
```

### Panorama: brak numeru seryjnego / licencja nie aktywuje się

**Przyczyna:** `panorama_serial_number` jest pusty lub niedostępny.

**Rozwiązanie:**
1. Połącz z Panoramą przez Bastion:
   ```bash
   az network bastion tunnel --name bastion-spoke2 --resource-group rg-spoke2-dc \
     --target-resource-id "$(terraform output -raw panorama_vm_id)" \
     --resource-port 443 --port 44300
   ```
2. Otwórz w **Microsoft Edge**: `https://127.0.0.1:44300`
3. Zaloguj się (`panadmin` / twoje hasło)
4. `Panorama → Setup → Management → General Settings → Serial Number` → wpisz serial z CSP Portal
5. `Panorama → Device → Licenses → Activate → podaj auth code`

Następnie dodaj serial do `terraform.tfvars`:
```hcl
panorama_serial_number = "007300014999"
```

### Firewall: brak konfiguracji po boocie (brak Panorama IP)

**Przyczyna:** Bootstrap z SA nie zadziałał.

**Diagnostyka:**
```bash
# Sprawdź co faktycznie jest w custom_data FW1
az vm show -g rg-transit-hub -n vm-panos-fw1 \
  --query 'osProfile.customData' -o tsv | base64 -d
# Powinno wyświetlić: storage-account=..., file-share=..., access-key=...

# Sprawdź czy blobs istnieją w SA
az storage blob list \
  --account-name "$(terraform output -raw bootstrap_storage_account)" \
  --container-name bootstrap \
  --auth-mode login --output table
```

**SSH do FW przez Bastion i sprawdź bootstrap status:**
```bash
az network bastion ssh --name bastion-spoke2 \
  --resource-group rg-spoke2-dc \
  --target-ip-address 10.0.0.4 \
  --auth-type password --username panadmin

# W PAN-OS CLI:
> show system bootstrap-status
> show system info | match "panorama|serial|hostname"
```

### SC3 – FW łączy się z Panoramą ale SSL fail

**Przyczyna:** FW nie ma Device Certificate (wymagane przez PAN-OS 11.x dla SC3).

**Rozwiązanie:** Device Certificate jest pobierany automatycznie gdy FW:
1. Ma aktywną licencję (authcodes w init-cfg → licensing server)
2. Ma dostęp do internetu (NAT Gateway na snet-mgmt)
3. Może połączyć się z `devca.paloaltonetworks.com`

Jeśli bootstrap działa poprawnie, Device Certificate jest pobierany automatycznie w ciągu ~5 min od aktywacji licencji. Sprawdź czy FW ma internet:
```bash
# SSH do FW
> ping source management count 3 host 8.8.8.8
```

### Storage Account 403 – Azure Policy

Jeśli `terraform apply -target=module.bootstrap` zgłasza błąd 403:
```
RequestDisallowedByPolicy: Storage accounts should restrict network access
```

Ustaw swój publiczny IP w `terraform.tfvars`:
```hcl
terraform_operator_ips = ["X.X.X.X"]  # curl -s https://api.ipify.org
```

---

## Dostęp do środowiska

Wszystkie zasoby są **bez publicznych IP** (poza LB i Front Door).

| Zasób | Jak uzyskać dostęp |
|-------|-------------------|
| **Panorama GUI** | Bastion tunnel → Edge → `https://127.0.0.1:44300` |
| **FW1 SSH/GUI** | `az network bastion ssh --target-ip-address 10.0.0.4` |
| **FW2 SSH/GUI** | `az network bastion ssh --target-ip-address 10.0.0.5` |
| **Windows DC** | Azure Portal → Spoke2 Bastion → Connect (IpConnect) |
| **Apache (Spoke1)** | `https://<external_lb_public_ip>` przez FW |

### Bastion tunnel dla Panoramy (HTTPS/GUI):
```bash
PANORAMA_ID=$(terraform output -raw panorama_vm_id)
az network bastion tunnel \
  --name bastion-spoke2 --resource-group rg-spoke2-dc \
  --target-resource-id "$PANORAMA_ID" \
  --resource-port 443 --port 44300

# W nowej zakładce Edge: https://127.0.0.1:44300
```

### Bastion SSH dla Panoramy (CLI):
```bash
az network bastion ssh \
  --name bastion-spoke2 --resource-group rg-spoke2-dc \
  --target-ip-address 10.0.0.10 \
  --auth-type password --username panadmin
```

---

## Kluczowe parametry środowiska

| Parametr | Wartość domyślna |
|----------|-----------------|
| Lokalizacja | Germany West Central (Frankfurt) |
| Panorama IP | 10.0.0.10 |
| FW1 mgmt IP | 10.0.0.4 |
| FW2 mgmt IP | 10.0.0.5 |
| Internal LB IP | 10.0.2.100 |
| Panorama VM size | Standard_D16s_v3 (16 vCPU / 64 GB) |
| FW VM size | Standard_D8s_v3 (8 vCPU / 32 GB) |
| Panorama log disk | 2 TB Premium SSD |
| Panorama Template Stack | Transit-VNet-Stack |
| Panorama Device Group | Transit-VNet-DG |

---

## Architektura sieciowa

```
Transit Hub VNet: 10.0.0.0/16
  snet-mgmt:    10.0.0.0/24   – FW mgmt (eth0), Panorama
  snet-untrust: 10.0.1.0/24   – FW untrust (eth1/1)
  snet-trust:   10.0.2.0/24   – FW trust (eth1/2)
  snet-ha:      10.0.3.0/24   – FW HA2 (eth1/3)

Spoke1 VNet: 10.1.0.0/16
  snet-workload: 10.1.0.0/24  – Apache VM (10.1.0.4)

Spoke2 VNet: 10.2.0.0/16
  snet-workload: 10.2.0.0/24  – Windows DC (10.2.0.4)
  AzureBastionSubnet           – Spoke2 Bastion
```

**UDR (User Defined Routes):**
- Spoke1 i Spoke2 mają UDR z `0.0.0.0/0 → 10.0.2.100` (Internal LB)
- Cały ruch east-west i outbound przez VM-Series

---

## Zniszczenie środowiska

```bash
terraform destroy
```

> **Uwaga:** `prevent_deletion_if_contains_resources = false` jest ustawione  
> dla resource groups, więc destroy usuwa wszystkie zasoby automatycznie.

---

## Licencja

MIT – patrz [LICENSE](LICENSE)
