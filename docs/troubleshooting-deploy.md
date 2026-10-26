# Troubleshooting — fresh-subscription deployment

Problems hit during a from-scratch deployment on a brand-new Azure
subscription, with symptoms, root cause and fix. Run
`bash scripts/preflight-check.sh` first — it detects most of them up front.

## 1. `terraform apply` hangs with an empty log, then `context deadline exceeded`

```
waiting for Subscription Provider (... Provider Name: "Microsoft.KeyVault")
to be registered: context deadline exceeded
```

**Cause:** on a fresh subscription the `azurerm` provider auto-registers
resource providers and blocks until each finishes. Azure can take up to
~30 min (even for providers this project does not use); Terraform prints
nothing meanwhile. Nothing is created.

**Fix:** register providers and wait for `Registered` before the first apply
(`preflight-check.sh` does it), then re-run `terraform apply`.

## 2. `SkuNotAvailable` / `NotAvailableForSubscription` on a VM

```
SkuNotAvailable: ... Standard_D16s_v3 is currently not available in location 'GermanyWestCentral'
```

**Cause:** v3 sizes are no longer offered on newer subscriptions, and on lab
subscriptions whole size families can be restricted per region (observed:
germanywestcentral had no usable D16/D8; polandcentral had D16s_v5/D8s_v5).

**Fix:** pick a region + sizes that pass `preflight-check.sh`
(`location`, `panorama_vm_size`, `fw_vm_size`, `app1_vm_size`, `dc_vm_size`).
Changing region after a partial deploy requires destroying what was created.

## 3. `Provider produced inconsistent result after apply … Root object was present, but now absent` / `already exists … needs to be imported`

**Likely cause** (observed, not confirmed with Microsoft): ARM eventual
consistency when resource groups with the **same names** are re-created right
after being destroyed. Azure briefly reports freshly created resources as
missing, so Terraform drops them from state while they still exist.

**Fix:** delete the (now orphaned) resource groups, wait until they are gone
(`az group list`), then re-run. After a `terraform destroy`, wait a few
minutes before re-applying with the same names.

## 4. FWs registered on Panorama but `Connected: no` forever

Symptoms (all at once):
- FW: `show panorama-status` → `Connected: no`; `show device-certificate status` → success
- FW `mp-log ms.log`: repeated `ssl channel established` + `device_registered no`
- Panorama system log: `Signed Cert '<fw serial>'` repeating every ~30 s
- `show devices all`: FW serials listed, `connected = no`

**Cause (most common):** the FW runs a **newer PAN-OS than Panorama**
(e.g. FW 12.2.3 vs Panorama 12.1.9). Panorama must be >= every managed
device. `pan_os_version = "latest"` caused it: the VM-Series `latest` image
was a newer train than the Panorama `latest` image. Check:
`show system info | match sw-version` on both.

**Fix:** set `pan_os_version` in `terraform.tfvars` to a release <= Panorama
and replace the FWs (this consumes new BYOL auth-code credits — deactivate
the old serials in CSP Portal first, see README):

```bash
terraform apply -target=module.firewall \
  -replace='module.firewall.azurerm_linux_virtual_machine.fw["fw1"]' \
  -replace='module.firewall.azurerm_linux_virtual_machine.fw["fw2"]' \
  -replace='module.firewall.null_resource.fw_set_userdata["fw1"]' \
  -replace='module.firewall.null_resource.fw_set_userdata["fw2"]'
bash scripts/register-fw-panorama.sh
```

`register-fw-panorama.sh` now detects this (version guard) and exits with
this hint instead of reporting success.

Other causes with the same top-level symptom: expired registration PIN,
depleted auth-code credits (`License Install Failed`), Panorama
`Failed to update DB` for vm-auth-key — see README Prerequisites and
`docs/troubleshooting-fw-cert.md`.

## 5. Phase 2a fails with `Post "https://127.0.0.1:44300/api": EOF`

**Likely cause:** the Bastion tunnel opened at script start does not survive
the Panorama restart in step 4b3 (disk-pair / log-index reinit) — the error
appeared on the first panos call right after the restart, and a re-run with a
fresh tunnel succeeded.

**Fix:** `configure-panorama.sh` now re-opens the tunnel and retries (up to 3
attempts; the apply is idempotent). If you run Phase 2 manually, just re-open
the tunnel and re-run `terraform apply`.

## 6. Push jobs report `not connected FAIL` for serials that no longer exist

**Cause:** stale FW serials from replaced VMs stay in `mgt-config devices`,
the Device Group and the Template Stack, so every commit-all shows FAIL.

**Fix:** `register-fw-panorama.sh` now removes serials found in this
project's Device Group / Template Stack / Collector Group that are not the
current FW1/FW2, then removes them from `mgt-config`. Manual cleanup (Panorama
CLI, configure mode) — **order matters**, `mgt-config` last, otherwise
Panorama refuses with `cannot be deleted because of references from …
log-collector-group -> default -> logfwd-setting`:

```
delete device-group <DG> devices <serial>
delete template-stack <stack> devices <serial>
delete log-collector-group default logfwd-setting devices <serial>
delete mgt-config devices <serial>
commit
```

## 7. AKS add-on: `could not download chart: no cached repo found … <repo>-index.yaml`

**Cause:** the Terraform `helm` provider reads the operator's local Helm
repository config. Any repo listed in `helm repo list` without a cached index
(here an unrelated `jupyterhub` repo) breaks the chart download — the
project's own chart repos are fine.

**Fix:** `helm repo update` (and `helm repo remove` unreachable repos), or run
the apply with an isolated Helm config:
`HELM_REPOSITORY_CONFIG=/tmp/helm-tf/repositories.yaml HELM_REPOSITORY_CACHE=/tmp/helm-tf/cache terraform apply`.
The apply is resumable — already created resources (AKS etc.) are kept.

## 8. AKS add-on: smoke tests fail on "WordPress NOT reachable via AFD"

Symptoms: pods Running, ingress-nginx answers 200 in-cluster, AFD health
probes (`Edge Health Probe`) reach the ingress with 200 — but the AFD URL
returns `404 Page not found` and your requests never show up in the ingress
log.

**Cause:** a newly created AFD endpoint was still propagating (observed
~25 min). AFD answers 404 itself until it does.

**Fix:** wait and re-check the URL; the smoke test now waits up to 18 min.
Also note when testing the External LB directly (`http://<ELB-IP>:8080`) from
a corporate network: a `503 Web Page Blocked` page comes from the corporate
proxy, not from the deployment. The EDL checks in the smoke test are
warnings only — the EDL has a private IP that a workstation normally cannot
reach.
