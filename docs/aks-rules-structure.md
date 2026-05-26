# AKS Egress Rules Structure (EDL anatomy + Panorama rule design)

Reference for the `optional/aks-deploy/` module's PAN-OS configuration. Read
this before changing the EDL generator or the Panorama rules.

> **Naming note — "Konnectivity" is not a typo.** "Konnectivity" (with
> capital K, looks like a misspelling of "connectivity") is the **official
> Kubernetes component name** — a portmanteau of "k8s" + "connectivity". It
> runs the control-plane↔node tunnel on TCP 9000; UDP 1194 was the
> OpenVPN-based `tunnel-front` predecessor that AKS still keeps around for
> legacy nodepool compatibility. Service objects in this module
> (`tcp-9000-konnectivity`, `udp-1194-konnectivity-legacy`) are deliberately
> spelled this way to match upstream — Kubernetes docs and Microsoft AKS
> outbound-rules docs both use the same spelling. Do not "fix" them.
> Source: <https://kubernetes.io/docs/tasks/extend-kubernetes/setup-konnectivity/>.

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

## Why a custom EDL instead of PANW SaaS EDL?

Palo Alto publishes ready-made dynamic lists for many cloud providers at
<https://saasedl.paloaltonetworks.com/feeds.html>. The natural question is:
why run our own EDL server when PANW already offers Azure feeds?

### What PANW SaaS EDL provides for Azure

Inventoried from the live site: **4 cloud variants** (`china`, `germany`,
`public`, `usgov` — these are Azure *sovereign clouds*, NOT Azure
*regions*), **101 distinct services** per cloud. Useful entries for an AKS
egress allowlist would be:

| Feed | What it covers | URL pattern |
|---|---|---|
| `azurecloud` | Every public-cloud IP CIDR Microsoft has assigned to Azure (any region, any service) | `…/feeds/azure/public/azurecloud/ipv4` |
| `azurecontainerregistry` | ACR endpoints (the customer-tenant `*.azurecr.io` data plane) | `…/feeds/azure/public/azurecontainerregistry/ipv4` |
| `microsoftcontainerregistry` | MCR (`mcr.microsoft.com` — kubelet/AKS base images) | `…/feeds/azure/public/microsoftcontainerregistry/ipv4` |
| `azurekubernetesservice` | *Does not exist* — there is no AKS-specific feed | n/a |

There are also no URL feeds — only IPv4 / IPv6 CIDRs.

### Why our custom EDL is more restrictive for AKS

1. **Region narrow vs cloud-wide IP allowlist.** PANW's `azurecloud/public`
   contains *every* Microsoft-assigned CIDR across every public Azure
   region (currently ~12,000 prefixes). An AKS node in `germanywestcentral`
   only needs to talk to `AzureCloud.germanywestcentral` (typically
   ~70-150 prefixes). The MS Service Tags JSON exposes this per-region
   breakdown — our generator filters to it; PANW's pre-built feed does
   not. Result: our IP allowlist is **2 orders of magnitude tighter** than
   `azurecloud/public` and still covers everything AKS in that region
   actually reaches (Konnectivity, ACR data plane, AAD, monitoring, etc.).

2. **Workload-shaped FQDN bundle.** PANW SaaS EDL has no URL feeds for
   Azure infrastructure at all, and no "AKS" feed bundling the
   non-`AzureCloud` endpoints AKS needs (Docker Hub for community images,
   `*.hcp.<region>.azmk8s.io/` for the managed control plane, `packages.
   microsoft.com` for kubelet host updates, GitHub for kustomize/helm
   pulls if used). With PANW feeds alone, the URL allowlist for an AKS
   workload would have to be hand-maintained anyway — which is what the
   custom EDL already does, with the entire bill of materials in one file
   (`fqdn_base_list.txt`) sourced from the MS AKS outbound-rules docs.

3. **Self-control / auditability.** The list contents are deterministic
   and reproducible — same generator, same inputs, same output. We can
   diff today's list against last week's and see exactly what changed,
   pin which Service Tags JSON snapshot we used, and add or remove
   entries in code review. PANW SaaS EDL is opaque curation by PANW — if
   a new CIDR appears we have no audit trail or rollback handle.

### When PANW SaaS EDL would still be the right tool

For SaaS workloads (M365 outbound from a user spoke, Salesforce, Zoom,
etc.) where the egress target is itself a SaaS provider's published
endpoint list, the PANW feeds are the right answer: pre-curated, per
service-area, frequently updated, zero ops cost. The custom-EDL approach
in this project is justified because **AKS is not a SaaS** — it's a
customer-managed infrastructure workload whose egress depends on what
images and add-ons that *specific* cluster runs. PANW can't ship a feed
for that.

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
| Dest addr | **`any`** (URL EDL can NOT be used as an address object in PAN-OS) |
| **Category** | **`AKS-Egress-FQDN` (URL EDL referenced as URL Category)** |
| Applications | web-browsing, ssl, apt-get, github, git (HTTP/HTTPS only — URL category only applies at L7) |
| Service | application-default |
| Action | allow |
| Log | yes (default-logging profile) |

URL EDLs in PAN-OS are referenced as URL categories (the `categories` field),
not as address objects, so this rule's `Dest addr` is `any` and the match
happens at Layer 7 against the URL category. Practical consequences:

- HTTP/HTTPS traffic to AKS FQDNs → matches this rule
- DNS / NTP / ICMP from AKS → does NOT match (no URL to categorize) →
  falls through to `Allow-Outbound-Internet` which has explicit App-IDs
  for these protocols
- Konnectivity (TCP 9000 / UDP 1194) — not HTTP/HTTPS — matches the
  IP-based `Allow-AKS-Egress-AzureCloud` rule instead

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
| **Translated source** | dynamic-ip-and-port on **ethernet1/2** (TRUST interface) |
| **Translated dest** | static `10.114.0.10:80` (AKS ingress-nginx internal LB) |

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
