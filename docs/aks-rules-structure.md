# AKS Egress Rules Structure (EDL anatomy + Panorama rule design)

Reference for the `optional/aks-deploy/` module's PAN-OS configuration. Read
this before changing the EDL generator or the Panorama rules.

## Architecture in one picture

```
                ┌───────────────────────────────────────────┐
                │  EDL Server (Ubuntu, mgmt VNet)           │
                │  ┌─────────────────────────────────────┐  │
                │  │ /opt/aks-edl/generate_aks_edl.py    │  │
                │  │   - reads fqdn_base_list.txt         │  │
                │  │   - fetches Azure Service Tags JSON  │  │
                │  │   - writes /var/www/html/edl/*.txt   │  │
                │  └─────────────────────────────────────┘  │
                │  ┌─────────────────────────────────────┐  │
                │  │ nginx :80                            │  │
                │  │   GET /edl/aks-egress-fqdn.txt       │  │
                │  │   GET /edl/aks-egress-ips.txt        │  │
                │  └─────────────────────────────────────┘  │
                │  ┌─────────────────────────────────────┐  │
                │  │ systemd timer (daily 03:17 UTC +     │  │
                │  │ on every boot)                       │  │
                │  └─────────────────────────────────────┘  │
                └───────────────────────────────────────────┘
                                  ▲
                                  │ HTTP pull every 1 h (FQDN) / 24 h (IP)
                                  │ Source: FW MGMT interface
                                  │
                ┌─────────────────┴─────────────────────────┐
                │  Panorama (mgmt VNet)                     │
                │                                            │
                │  External Dynamic Lists:                  │
                │   ├── AKS-Egress-FQDN   (URL list)        │
                │   └── AKS-Egress-IPs    (IP  list)        │
                │                                            │
                │  Address objects: AKS-Spoke3-CIDR,         │
                │                    External-LB-PIP         │
                │  Service objects:  tcp-9000-konnectivity,  │
                │                    udp-1194-konnectivity-  │
                │                    legacy, tcp-8080-wp     │
                │                                            │
                │  Security rules (BEFORE Allow-Outbound):   │
                │   ├── Allow-AKS-Egress-FQDN                │
                │   ├── Allow-AKS-Egress-AzureCloud          │
                │   └── Allow-Inbound-WordPress              │
                │                                            │
                │  NAT rule (top): DNAT-Inbound-WordPress    │
                └────────────────┬───────────────────────────┘
                                 │ commit-all shared-policy
                                 ▼
                         FW1 + FW2 enforce rules
```

## URL EDL anatomy

The FQDN list at `/var/www/html/edl/aks-egress-fqdn.txt` is a plain text
file PAN-OS pulls every hour. Each non-comment line is an FQDN entry the
firewall matches against destination URLs.

### Critical formatting rules

1. **Wildcards need a trailing slash.** PAN-OS URL EDL with wildcards
   (`*.example.com`) silently fails the match unless the line is written as
   `*.example.com/`. Our generator adds the slash for every non-comment
   entry, so source files in `fqdn_base_list.txt` MUST omit it (otherwise
   you get a double `//`).

2. **No HTTPS scheme prefix.** PAN-OS URL EDL strips `http://` and
   `https://` from entries but it's cleaner to leave them off in the
   first place. Just write the FQDN.

3. **Comments start with `#` or `;`.** Generator preserves them and PAN-OS
   ignores them. Helpful for grouping entries by category (we use that
   structure in `fqdn_base_list.txt`).

4. **Region placeholder.** Source file has `*.hcp.${REGION}.azmk8s.io`;
   generator substitutes the value of `aks_region` from `settings.json`
   before writing. This is the ONLY templated entry — everything else is
   region-agnostic.

### What the FQDN list contains (by category)

| Category | Entries | Why |
|---|---|---|
| AKS control plane | `*.hcp.<region>.azmk8s.io/`, `management.azure.com/`, `login.microsoftonline.com/` | Node ↔ API server, ARM operations, AAD auth |
| Container registries | `mcr.microsoft.com/`, `*.data.mcr.microsoft.com/`, `mcr-0001.mcr-msedge.net/` | Microsoft Container Registry (system images) |
| Package mirrors | `packages.microsoft.com/`, `packages.aks.azure.com/`, `acs-mirror.azureedge.net/` | apt-get (azurecli, kubectl, azure-cli moby, CNI binaries) |
| Ubuntu OS | `security.ubuntu.com/`, `azure.archive.ubuntu.com/`, `changelogs.ubuntu.com/`, `snapshot.ubuntu.com/` | Node OS patching |
| Monitoring (Container Insights) | `*.ods.opinsights.azure.com/`, `*.oms.opinsights.azure.com/`, `*.monitoring.azure.com/` | Optional add-on; pre-allowed |
| Azure Policy | `data.policy.core.windows.net/`, `store.policy.core.windows.net/` | Optional add-on |
| Cluster extensions | `*.dp.kubernetesconfiguration.azure.com/`, `arcmktplaceprod.azurecr.io/` | Optional |
| WordPress workload | `docker.io/`, `registry-1.docker.io/`, `auth.docker.io/`, `*.docker.com/` | Bitnami images |
| Helm chart repos | `charts.bitnami.com/`, `kubernetes.github.io/` | Chart downloads at first apply |
| ingress-nginx | `registry.k8s.io/`, `*.pkg.dev/` | Controller image |

## IP EDL anatomy

The IP list at `/var/www/html/edl/aks-egress-ips.txt` is also plain text,
one CIDR per line. Generated from the Azure Service Tags JSON published
weekly by Microsoft, filtering on `AzureCloud.<region>` (case-insensitive).

### Source-of-truth resolution

```
https://www.microsoft.com/en-us/download/confirmation.aspx?id=56519
    │
    │  (scrape with regex r'https://download\.microsoft\.com/.../ServiceTags_Public_\d+\.json')
    ▼
https://download.microsoft.com/.../ServiceTags_Public_20260520.json
    │
    │  (fetch + parse)
    ▼
values[name="AzureCloud.WestEurope"].properties.addressPrefixes  → IPv4 CIDR list
```

The URL changes weekly (Microsoft doesn't publish a stable URL), so the
scrape step is mandatory. If MS changes the page structure, the regex
`SERVICE_TAGS_URL_RE` in `generate_aks_edl.py` needs updating.

### Refresh interval

PAN-OS pulls the IP list every 24 h (the MS JSON updates weekly anyway).
The systemd timer on the EDL server regenerates the file daily at 03:17 UTC,
so the IPs are at most ~30 h stale in PAN-OS.

## Panorama rule design

Three security rules + one NAT rule, all in the `Transit-VNet-DG` device
group.

### Position: BEFORE `Allow-Outbound-Internet`

The existing `Allow-Outbound-Internet` rule is broad: `src=any/trust → any/untrust`
with app-IDs for web-browsing, ssl, dns, ntp-base, apt-get, etc. If our AKS
rules came AFTER it, they'd never match — the broad rule would catch all AKS
traffic first.

Putting them BEFORE means EDL-based matches take precedence:
- AKS traffic to a FQDN in `AKS-Egress-FQDN` → matches `Allow-AKS-Egress-FQDN` (logged + allowed)
- AKS traffic to an IP in `AKS-Egress-IPs` on TCP 9000 / UDP 1194 → matches `Allow-AKS-Egress-AzureCloud`
- AKS traffic to anything else → falls through to `Allow-Outbound-Internet` (broader, app-ID based)
- Everything else still hits `Deny-All` at the bottom

This is **defense in depth**: even if the EDL is stale or missing a new
endpoint, generic web traffic still works through the broader rule. The
EDL rules add visibility (you can see which AKS endpoints are being hit)
and prepare for stricter policies later (just set `Allow-Outbound-Internet`
to `deny` and only EDL-allowed traffic gets out).

### Rule 1: `Allow-AKS-Egress-FQDN`

| Field | Value |
|---|---|
| Source zone | trust |
| Source addr | `AKS-Spoke3-CIDR` (10.114.0.0/16) |
| Dest zone | untrust |
| Dest addr | `AKS-Egress-FQDN` (URL EDL) |
| Applications | web-browsing, ssl, dns, ntp-base, apt-get, github, git, icmp, ping |
| Service | application-default |
| Action | allow |
| Log | yes (default-logging profile) |

### Rule 2: `Allow-AKS-Egress-AzureCloud`

| Field | Value |
|---|---|
| Source zone | trust |
| Source addr | `AKS-Spoke3-CIDR` |
| Dest zone | untrust |
| Dest addr | `AKS-Egress-IPs` (IP EDL) |
| Applications | any (Konnectivity is a custom protocol; service ports give the granularity) |
| Service | `tcp-9000-konnectivity`, `udp-1194-konnectivity-legacy` |
| Action | allow |
| Log | yes |

### Rule 3: `Allow-Inbound-WordPress`

| Field | Value |
|---|---|
| Source zone | untrust |
| Source addr | any |
| Dest zone | trust (POST-NAT — AKS is in trust) |
| Dest addr | `External-LB-PIP` (PRE-NAT — PAN-OS DNAT semantics) |
| Applications | web-browsing, ssl |
| Service | `tcp-8080-wordpress` |
| Action | allow |
| Log | yes |

### NAT rule: `DNAT-Inbound-WordPress`

| Field | Value |
|---|---|
| Position | top |
| Source zone | untrust |
| Dest zone | untrust (PRE-NAT — destination is still the External LB PIP) |
| Dest interface | ethernet1/1 (untrust) |
| Source addr | any |
| Dest addr | `External-LB-PIP` |
| Service | `tcp-8080-wordpress` |
| **Translated source** | dynamic-ip-and-port on **ethernet1/2** (TRUST interface — symmetric-routing fix, see below) |
| **Translated dest** | static `10.114.0.10:80` (AKS ingress-nginx internal LB) |

#### Why SNAT-to-trust?

Same rationale as the Apache DNAT rule in `modules/panorama_config/main.tf`:
without SNAT-to-trust, the AKS ingress response goes to the FW untrust IP
(say `10.110.129.4`), arrives at the FW via VNet peering on the untrust
interface, but the session is on the trust interface → asymmetric routing →
FW drops the response.

With SNAT-to-trust (e.g., `10.110.0.4`), the response goes to the trust IP
→ arrives on the trust interface → matches the session → forwarded back to
the client. Symmetric, works.

## Extending the rules

### Add a new FQDN to the EDL

1. Edit `optional/aks-deploy/modules/edl_server/files/fqdn_base_list.txt`
2. Either re-apply terraform (cloud-init re-runs) OR `ssh edladmin@10.255.2.4` then `sudo cp fqdn_base_list.txt /opt/aks-edl/` and `sudo systemctl start aks-edl-update.service`
3. PAN-OS picks up the new entry on the next refresh (max 1 h). Force a manual refresh: Panorama → Objects → External Dynamic Lists → `AKS-Egress-FQDN` → "Check Now"

### Add support for a new AKS region

1. Edit `optional/aks-deploy/terraform.tfvars`: change `aks_region` value
2. `terraform apply` — re-runs cloud-init (writes new `settings.json` to EDL server) → generator regenerates with new region → URL list now has new `*.hcp.<region>.azmk8s.io/` + IP list now has new `AzureCloud.<region>` CIDRs
3. PAN-OS picks up on next refresh

### Tighten the rules: remove fallthrough to `Allow-Outbound-Internet`

Once you're confident the EDL covers all needed AKS endpoints:

1. Edit `modules/panorama_config/main.tf` security rule `Allow-Outbound-Internet`:
   - Add `source_addresses` exclusion for `AKS-Spoke3-CIDR`, OR
   - Move it BELOW the AKS rules and add an explicit `Deny-AKS-Outbound-Fallback` rule between them
2. Re-run Phase 2a + 2b, OR run `panos_panorama_security_rule_group` here directly via XML API

Either way, test in monitoring mode first: change rule action to `alert` (PAN-OS only) for a week and watch which AKS endpoints are denied.

## Common gotchas

| Symptom | Likely cause | Fix |
|---|---|---|
| EDL "List capacity: 0" on PAN-OS | URL EDL pulled but list empty/malformed | Test directly: `curl http://10.255.2.4/edl/aks-egress-fqdn.txt` from FW MGMT. If 200 with content, check PAN-OS service route is via MGMT (Device → Setup → Services). |
| FQDN match works for `mcr.microsoft.com` but not `*.data.mcr.microsoft.com` | Missing trailing slash on wildcard | Verify the file content has `*.data.mcr.microsoft.com/` (with `/`). |
| IP list 0 CIDRs | `AzureCloud.<region>` not found in JSON | Generator logs to `/var/log/aks-edl-update.log` — most likely cause: wrong `aks_region` value (e.g., `germanywest` vs `germanywestcentral`). |
| Konnectivity blocked despite IP EDL | TCP 9000 IS a real port but the destination isn't in `AzureCloud.<region>` — it's actually in `AzureFrontDoor.Backend` or `AzureKubernetesService` | Add the appropriate service-tag to the generator (extract a second CIDR list and add to the IP EDL). |
| AFD endpoint shows 502 | LB rule 8080 not added OR DNAT rule not pushed | See troubleshooting in `docs/aks-runbook.md`. |
