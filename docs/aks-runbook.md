# AKS Module Runbook (`optional/aks-deploy/`)

Step-by-step deployment, verification, and teardown for the optional AKS +
WordPress module. Mirrors the structure of `docs/dc-promote-runbook.md`.

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
