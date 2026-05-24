# AKS Module Runbook (`optional/aks-deploy/`)

Step-by-step deployment, verification, and teardown for the optional AKS +
WordPress module. Mirrors the structure of [`docs/dc-runbook.md`](dc-runbook.md).

## Architecture

Baseline transit topology + everything this module adds (spoke3 VNet, EDL
server in management VNet, WordPress AFD endpoint, port-8080 LB rule). All
existing transit resources are present unchanged — the optional module is
strictly additive, no edits to root state.

```
                            ┌───────────────┐
                            │   INTERNET    │
                            └───────┬───────┘
                                    │
        ┌───────────────────────────┴────────────────────────────┐
        │                                                        │
┌───────▼───────────────────┐                  ┌────────────────▼─────────────────┐
│  AFD: original endpoint   │                  │  AFD: NEW endpoint               │
│  (Apache via FW DNAT)     │                  │  endpoint-panos-wordpress-XXXX   │
│  Front Door Premium       │                  │  origin = External LB :8080      │
└───────────┬───────────────┘                  └────────────────┬─────────────────┘
            │ HTTPS :443                                        │ HTTP :8080
            │                                                   │
            └────────────────┬──────────────────────────────────┘
                             │
              ┌──────────────▼──────────────────────────────────┐
              │  External LB (Standard) — pip-external-lb       │
              │  Rules: TCP 80 (Apache), TCP 443 (Apache),      │
              │         TCP 8080 (WordPress)  ← NEW from AKS    │
              │  Health: TCP 22 (5s/2 probes)                   │
              │  SNAT outbound rule                             │
              └──────────────┬──────────────────────────────────┘
                             │
  ┌──────────────────────────▼──────────────────────────────────────────────────┐
  │  Transit Hub VNet (10.110.0.0/16)                                           │
  │                                                                             │
  │    snet-public (10.110.129.0/24) ─── FW eth1/1 (untrust, DHCP)              │
  │         ┌──────────┐  ┌──────────┐                                          │
  │         │   FW1    │  │   FW2    │  VM-Series farm behind Azure LB          │
  │         └────┬─────┘  └────┬─────┘  Panorama-managed (Transit-VNet-DG +     │
  │    snet-private (10.110.0.0/24)     Template Stack); EDL rules pushed here  │
  │         │                  │        via commit-all shared-policy            │
  │    snet-mgmt (10.110.255.0/24) ─── FW eth0 (management)                     │
  │         │  NAT GW (license/updates)                                         │
  └─────────┼──────────────────────────────────────────────┬────────────────────┘
            │                  │ peering                  │ peering
            │       ┌──────────▼──────────┐    ┌──────────▼────────────────────┐
            │       │  Internal LB (Std)  │    │  Management VNet              │
            │       │  10.110.0.100       │    │  (10.255.0.0/16)              │
            │       │  HA Ports (All/0)   │    │                               │
            │       └──────────┬──────────┘    │  Panorama  10.255.0.4         │
            │                  │               │  Bastion (tunnel + IpConnect) │
            │       next-hop=VirtualAppliance  │                               │
            │                  │               │  snet-edl   10.255.2.0/27 NEW │
            │                  │               │   └─ vm-edl-server 10.255.2.4 │
            │                  │               │      - nginx :80              │
            │                  │               │      - python EDL generator   │
            │                  │               │      - systemd timer daily    │
            │                  │               └───────────────┬───────────────┘
            │                  │                               │ HTTP pull
            │                  │                               │ EDL refresh
            │                  │                               │ FW MGMT → EDL
            │                  │                               │ (URL hourly,
            │                  │                               │  IP daily 03:00)
  ┌─────────▼──────────────────▼─────┐                         │
  │   ┌─────────────────────────┐   ◄───────────────── peering ┘ + (transit peering)
  │   │  Spoke1: App1 VNet      │   │
  │   │  (10.112.0.0/16)        │   │
  │   │  Ubuntu+Apache 10.112.0.4│  │
  │   └─────────────────────────┘   │
  │                                 │
  │   ┌─────────────────────────┐   │
  │   │  Spoke2: App2 VNet      │   │   ┌─────────────────────────────────────┐
  │   │  (10.113.0.0/16)        │   │   │  Spoke3: AKS VNet      NEW          │
  │   │  Windows DC 10.113.0.4  │   │   │  (10.114.0.0/16)                    │
  │   └─────────────────────────┘   │   │                                     │
  │                                 │   │   snet-aks-nodes (10.114.0.0/24)    │
  │   ┌─────────────────────────┐   │   │     └─ 2× AKS nodes (D2s_v3)        │
  │   │  Spoke3: AKS VNet  NEW  │───┼──►│        - Azure CNI Overlay          │
  │   │  (10.114.0.0/16)        │   │   │        - pod CIDR 10.244.0.0/16     │
  │   │  see right-side detail  │   │   │        - WordPress + MariaDB pods   │
  │   └─────────────────────────┘   │   │                                     │
  └─────────────────────────────────┘   │   snet-aks-ilb (10.114.1.0/27)      │
                                        │     └─ ingress-nginx ILB            │
                                        │        10.114.1.4 :80               │
  Egress from AKS pods:                 │                                     │
  ──────────────────────                │   UDR (rt-app3-aks):                │
  pod → kube-proxy → node →             │     0.0.0.0/0 → 10.110.0.100 (ILB)  │
  UDR(0/0 → 10.110.0.100) →             │     BGP propagation: OFF            │
  FW(EDL match: docker.io, MCR,         │                                     │
   *.hcp.<region>.azmk8s.io/,           │   peerings:                         │
   AzureCloud.<region>) →               │     Transit Hub ↔ Spoke3 (data)     │
  SNAT untrust → ELB → Internet         │     Mgmt VNet  ↔ Spoke3 (Bastion)   │
                                        └─────────────────────────────────────┘
  Inbound to WordPress:
  ────────────────────
  Client → AFD :443 → AFD origin (External LB :8080) →
  LB rule rule-http-8080-wordpress (floating IP) → FW DNAT-Inbound-WordPress →
  10.114.1.4 :80 (ingress-nginx ILB) → wordpress ClusterIP :80 → pod
```

See [`aks-rules-structure.md`](aks-rules-structure.md) for the Panorama
rule/EDL anatomy detail.

## What this deploys

A new spoke (`spoke3`, 10.114.0.0/16) added to the existing transit hub with:

| Component | Resource(s) | Notes |
|---|---|---|
| EDL server | `vm-edl-server` (Ubuntu 22.04), `nsg-edl`, subnet `snet-edl` (10.255.2.0/27) in management VNet | Hosts nginx + Python EDL generator. Serves URL+IP lists to Panorama |
| Spoke3 network | RG `rg-app3-aks`, VNet `vnet-app3-aks`, subnets `snet-aks-nodes` + `snet-aks-ilb`, peering, UDR `rt-app3-aks` | New AKS spoke |
| Panorama objects | 2 EDL objects, 2 address objects, 3 service objects, 3 security rules, 1 NAT rule | Added to existing `Transit-VNet-DG` device group, pushed via `commit-all shared-policy` |
| AKS cluster | `aks-spoke3-wordpress` (Azure CNI Overlay, UDR egress, 2 nodes, public API) | ~10-15 min boot |
| WordPress | `helm_release` for ingress-nginx + bitnami/wordpress + MariaDB | Persistent storage via Azure Disk CSI |
| AFD | New `endpoint-panos-wordpress` under existing `afd-panos-transit` profile + new External LB rule on port 8080 | Hostname like `wordpress-XXXX.z01.azurefd.net` |

Total deploy time: **~25-35 min**, destroy ~15 min.

## Prerequisites

1. **Root deployment fully done.** Phase 1a, 1b, 2a, 2b all complete. Verify:
   - `cd ../..` (repo root) → `terraform output panorama_vm_id` returns a value
   - In Panorama GUI: Device Group `Transit-VNet-DG` exists with security rule `Allow-Outbound-Internet` (the AKS rules use `position_keyword=before` referencing this rule)
   - FW1 + FW2 connected to Panorama (Panorama → Panorama → Managed Devices → "Connected" status)
2. **Azure CLI authenticated** to the hub subscription:
   ```bash
   az login --use-device-code
   az account set --subscription <hub-subscription-id>
   ```
3. **Active Bastion tunnel** to Panorama (port 44300). Start in a separate
   terminal and leave open for the duration of the apply:
   ```bash
   PANORAMA_ID=$(cd ../.. && terraform output -raw panorama_vm_id)
   az network bastion tunnel \
     --name bastion-management \
     --resource-group rg-transit-hub \
     --target-resource-id "$PANORAMA_ID" \
     --resource-port 443 \
     --port 44300
   ```
4. **kubectl installed** locally (used by smoke tests). If missing:
   ```bash
   az aks install-cli
   ```

## Deploy

```bash
cd optional/aks-deploy/

cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — fill REPLACE_ME values:
#   hub_subscription_id      (same as root)
#   external_lb_public_ip    (cd ../.. && terraform output -raw external_lb_public_ip_address)
#   panorama_password        (root admin_password)
#   edl_admin_password       (reuse panorama_password or set a separate one)
#   wp_admin_password        (your WordPress admin password)

terraform init
terraform apply
```

Watch the apply output:

| Phase | What's happening | Expected duration |
|---|---|---|
| A. EDL server | Subnet, NSG, NIC, VM cloud-init (nginx + python) | 3-5 min |
| (wait) | Polling `curl http://<edl_ip>/edl/aks-egress-fqdn.txt` for 200 | up to 10 min |
| B. Spoke3 network | RG, VNet, 2 subnets, 2 peerings, route table | 1-2 min |
| C. Panorama rules | EDL/address/service/security/NAT objects via panos provider + commit + commit-all push to FWs | 3-5 min |
| D. AKS cluster | `azurerm_kubernetes_cluster` + UAI + role assignment | 10-15 min |
| E. WordPress | 2 helm_release (ingress-nginx → bitnami/wordpress) | 5-7 min |
| F. AFD + LB rule | New endpoint, origin group, origin, route + 8080 LB rule | 1-2 min |
| G. Smoke tests | `verify_deployment.sh` runs kubectl/curl checks | 2-5 min |

Final output:
```
wordpress_url = "https://wordpress-XXXX.z01.azurefd.net"
wordpress_admin_login = "https://wordpress-XXXX.z01.azurefd.net/wp-login.php"
```

Open `wordpress_url` in a browser → WordPress homepage. Open
`wordpress_admin_login` → log in as `wpadmin` / `<wp_admin_password>`.

## Verification (manual, post-deploy)

### Browser
1. Open `wordpress_url` → expect WordPress default homepage with the configured blog name
2. Open `wordpress_url/wp-admin` → log in → expect dashboard
3. Optional: create a post, verify it persists across pod restart (`kubectl delete pod -n wordpress -l app.kubernetes.io/name=wordpress`)

### Panorama
1. Objects → External Dynamic Lists → `AKS-Egress-FQDN` → click "Check Now" → expect status = success, list size > 30
2. Objects → External Dynamic Lists → `AKS-Egress-IPs` → "Check Now" → expect list size > 100 CIDRs
3. Policies → Security → Pre Rules → expect 3 new rules above `Allow-Outbound-Internet`:
   - `Allow-AKS-Egress-FQDN`
   - `Allow-AKS-Egress-AzureCloud`
   - `Allow-Inbound-WordPress`
4. Policies → NAT → Pre Rules → expect `DNAT-Inbound-WordPress` at top
5. Monitor → Traffic → filter `rule eq 'Allow-AKS-Egress-FQDN'` → expect log entries (AKS image pulls)

### kubectl
```bash
$(terraform output -raw aks_get_credentials_command)
kubectl get nodes                           # 2 nodes Ready
kubectl get pods -A                          # No CrashLoopBackOff / ImagePullBackOff
kubectl get svc -n ingress-nginx             # LoadBalancer with EXTERNAL-IP=10.114.0.10
kubectl get ingress -n wordpress             # Address=10.114.0.10
```

## Troubleshooting

### Symptom: AKS cluster stuck in "Creating" for > 15 min

Cause: FW security rules didn't push before AKS started → kubelet image pulls
denied by `Deny-All`.

Fix:
1. On Panorama → Commit → Push to Devices → push manually
2. If still stuck after another 10 min, check Panorama Monitor → Traffic with
   filter `application eq 'docker-registry'` or `destination-port eq 9000` —
   denies indicate the rules aren't on the FWs yet
3. Worst case: `terraform destroy -target=module.aks_cluster` and re-apply

### Symptom: Pods stuck in `ImagePullBackOff`

Cause: image registry (MCR, Docker Hub, registry.k8s.io) not reachable.

Fix:
1. Verify EDL list contains the FQDN — `curl http://<edl_ip>/edl/aks-egress-fqdn.txt | grep -F docker.io`
2. Verify Panorama EDL pulled — Panorama → Objects → External Dynamic Lists → `AKS-Egress-FQDN` → check "List capacity"
3. Verify FW pulled the EDL — on FW CLI: `request system external-list refresh name AKS-Egress-FQDN` then `show external-list`
4. Verify traffic actually denied — Monitor → Traffic, filter `source eq 10.114.0.0/24` and look for `deny` entries

### Symptom: `terraform apply` fails on `module.panorama_aks_rules` with "connection refused"

Cause: Bastion tunnel to Panorama isn't running on port 44300.

Fix: start the tunnel (see Prerequisites step 3), then re-run `terraform apply`.
The apply is idempotent; resources that already created will not be touched.

### Symptom: WordPress NOT reachable via AFD URL (smoke test fails)

Common causes (verify in order):
1. **AFD origin probe still failing** — Azure Portal → AFD profile → Origin Groups → `og-aks-wordpress` → check "Origin status" column. Probe interval is 30s; allow 2-3 min after deploy.
2. **LB rule 8080 not active** — Azure Portal → `lb-external-panos` → Load balancing rules → `rule-http-8080-wordpress` should be Healthy.
3. **Panorama DNAT rule not pushed** — Panorama → Monitor → Traffic, filter `(destination-port eq 8080)`. No entries means the rule isn't matching.
4. **FW security rule not pushed** — same filter. Look for `deny` action with rule `Deny-All` → security rule didn't push to FW.
5. **AKS ingress-nginx not Ready** — `kubectl get pods -n ingress-nginx` should show 1 controller Running. If not, `kubectl describe pod` for events.

## Teardown

```bash
cd optional/aks-deploy/
terraform destroy
```

Destroy order (terraform handles automatically via reverse dependency graph):

1. `null_resource.smoke_tests` removed (no-op on destroy)
2. `module.frontdoor_wordpress` — AFD endpoint, route, origin, origin group, **+ new LB rule on port 8080**
3. `module.wordpress` — helm uninstall (WordPress, then ingress-nginx)
4. `module.aks_cluster` — AKS cluster + UAI + role assignment + auto-cleanup of `MC_*` resource group
5. `module.panorama_aks_rules` — security rules, NAT rule, address objects, service objects, EDL objects → commit + commit-all to remove them from FWs
6. `module.aks_network` — UDR, peerings, subnets, VNet, RG
7. `module.edl_server` — VM, NIC, NSG, subnet

After destroy, verify:
- `kubectl get nodes` fails (cluster gone)
- Panorama Objects → External Dynamic Lists → `AKS-Egress-FQDN` is absent
- Panorama Policies → Security → `Allow-AKS-Egress-*` absent
- Azure Portal: `rg-app3-aks` deleted; the auto-generated `MC_rg-app3-aks_aks-spoke3-wordpress_*` is also gone
- Root module state is untouched (Apache stack continues working)

## Notes

- **EDL refresh**: the URL list refreshes hourly (PAN-OS interval), regenerated daily at 03:17 UTC by the systemd timer on the EDL server. If the MS docs add new FQDNs, edit `optional/aks-deploy/modules/edl_server/files/fqdn_base_list.txt` and `terraform apply` (this re-writes the file via cloud-init replay — easiest to `terraform taint module.edl_server.azurerm_linux_virtual_machine.edl` then re-apply, OR ssh into the VM and `cp` the new file then `systemctl start aks-edl-update.service`).

- **IP refresh fallback**: if the Microsoft Service Tags JSON download fails (network glitch, MS rate-limiting), the previous IP list stays in place — generator logs the failure to `/var/log/aks-edl-update.log` but does NOT replace the existing file with an empty one. Stale list is preferable to no list.

- **Adding a new AKS region**: change `aks_region` in `terraform.tfvars`, re-apply. The generator will substitute `${REGION}` in the FQDN list with the new region and start serving the new `*.hcp.<region>.azmk8s.io/` entry. PAN-OS picks up the change on the next refresh interval (max 1 h).

## Known gotchas (deploy-time)

Four independent things bit the first end-to-end deploy on 2026-05-24 — each
is fixed in code now (see commits `1f53572`, `f10b58f`, `fe7bc13`) but worth
knowing about when reading the module or copying patterns from it.

### `terraform.tfvars.example` has `germanywestcentral` — your hub may not

The example uses `location = "germanywestcentral"` / `aks_region = "germanywestcentral"`.
If the root deploy lives in a different region (e.g. `francecentral`), copying
the example verbatim creates the EDL NSG in the wrong region. The subsequent
NSG↔subnet association then fails with:

```
InvalidResourceReference: Resource ...RG-TRANSIT-HUB.../NSG-EDL was not
found. Please make sure that the referenced resource exists, and that
both resources are in the same region.
```

The uppercase in the path is an Azure-side normalisation artefact — the real
problem is the cross-region reference (Azure surfaces the same generic error).

**Fix**: always pull the region from the root deploy's `terraform.tfvars`
before staging the AKS tfvars. The `location` and `aks_region` values must
match the transit hub region exactly.

### Bitnami image deprecation (2025-08) — `docker.io/bitnami/*` returns 404

Bitnami moved free versioned image tags from `docker.io/bitnami/*` to
`docker.io/bitnamilegacy/*` in August 2025. The pinned chart `wordpress 23.0.0`
still references `bitnami/wordpress:6.5.5-debian-12-r7` and
`bitnami/mariadb:11.4.2-debian-12-r0`, both of which now 404 on pull. Pods get
stuck in `ImagePullBackOff` and the `helm_release` times out at 900 s.

**Fix already in code** (`modules/wordpress/main.tf`): two `image.repository`
overrides redirect to `bitnamilegacy/wordpress` / `bitnamilegacy/mariadb` with
the same tag values. The legacy org is still public; no auth needed.

**Long-term**: any future bump of `wordpress_chart_version` needs to verify
that the new chart's pinned tags still exist on `bitnami/*` or require the
same legacy redirect. Switching off Bitnami images entirely (or paying for
Bitnami Secure Images) is the durable answer.

### AKS auto-enables OIDC issuer and refuses to disable

Azure turns `oidc_issuer` on at cluster create and rejects updates that try
to switch it off (`OIDCIssuerFeatureCannotBeDisabled`, HTTP 400). Without
`oidc_issuer_enabled = true` pinned in the resource, the provider default
(`false`) drifts on the second apply and the in-place update fails — which
blocks every downstream step (helm chart updates, AFD wiring, smoke tests).

**Fix already in code** (`modules/aks_cluster/main.tf`): `oidc_issuer_enabled = true`.
No effect on first deploy (Azure was going to enable it anyway); just keeps
the diff empty across reruns.

### Bitnami WordPress chart `ingress.hostname` must be a valid DNS name

The Bitnami chart requires a single hostname in `ingress.hostname`. Bare
`*` is not valid in the Kubernetes Ingress spec (`spec.rules[].host` must
be exact or `*.<suffix>`). The prior chart-Ingress configuration fails
admission and the helm_release reports an Ingress validation error.

AFD currently sends the External LB public IP as the Host header (an IP
isn't a valid `host` either, so there's no chart-side hostname pin that
would work cleanly anyway).

**Fix already in code** (`modules/wordpress/main.tf`): disable the chart's
built-in Ingress (`ingress.enabled = false`) and create a separate
`kubernetes_ingress_v1 "wordpress"` with `default_backend` (no rules =
catch-all). Any Host header — including bare IP — now routes to the chart's
`wordpress` ClusterIP service on port 80.

### `scripts/verify_deployment.sh` is macOS-incompatible (open)

The smoke test script uses two GNU-only constructs:

- `date -Is` — BSD `date` on macOS rejects the `-I` flag
- A `kubectl get pods -o jsonpath=...` query with `@.metadata.namespace=="wordpress" || ...` syntax that BSD bash interprets differently

On macOS the smoke test fails even when the deploy is functionally healthy
(WordPress reachable via AFD, pods Running). When `terraform apply` reports
smoke-test failure, verify success out-of-band:

```bash
curl -fsSL --max-time 15 "$(terraform output -raw wordpress_url)" | head
kubectl get pods -n wordpress
```

**Not fixed in this round.** Two options for a follow-up: (a) replace
`date -Is` with `date '+%Y-%m-%dT%H:%M:%S%z'` and rewrite the jsonpath query
to avoid `||` (use two separate calls + shell concat), or (b) just run the
deploy from a Linux host / dev container where the script's assumptions hold.
