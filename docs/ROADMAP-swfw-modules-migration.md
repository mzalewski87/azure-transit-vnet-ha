# Roadmap: Migration to PaloAltoNetworks/swfw-modules (v2 of this project)

**Status:** Future scope — not implemented in current code.
**Why deferred:** the official `bootstrap` sub-module is incompatible with this
deployment environment (corporate SSL inspection blocks PUT-with-body to
`*.file.core.windows.net`). The remaining sub-modules are good candidates for
a partial adoption that would cut ~1,500 LOC of custom code.

This document captures the migration plan so v2 work can pick up cleanly.

---

## Reference

- Module set: <https://registry.terraform.io/modules/PaloAltoNetworks/swfw-modules/azurerm/latest>
- GitHub: <https://github.com/PaloAltoNetworks/terraform-azurerm-swfw-modules>
- Latest verified: **v3.4.5** (2026-02-05)
- Reference example matching this project's topology: **`examples/vmseries_transit_vnet_common`**
  - "Common Firewall" pattern — one HA pair handles inbound + outbound +
    east-west (vs. `vmseries_transit_vnet_dedicated` which uses a separate
    inbound FW pair, recommended by PANW for production)

## Sub-module mapping

| Custom module (this repo) | swfw-modules sub-module | Decision | Notes |
|---|---|---|---|
| `modules/networking` (~1,200 LOC) | `vnet` + `vnet_peering` | **REPLACE** | Cleaner API, peering built-in, well-tested |
| `modules/loadbalancer` (~240 LOC) | `loadbalancer` | **REPLACE** | External + Internal LB + HA Ports patterns ready |
| `modules/panorama` (~185 LOC) | `panorama` | **REPLACE** | Handles NIC ordering, managed identity correctly |
| `modules/firewall` (~217 LOC after C1 refactor) | `vmseries` | **EVALUATE** | Verify swfw-modules `vmseries` handles the marketplace `userData` workaround we have in `null_resource.fw_set_userdata`. If it does NOT, keep custom — this workaround is load-bearing |
| `modules/bootstrap` (~80 LOC after A1) | `bootstrap` + (deprecated) `panos-bootstrap` | **KEEP CUSTOM** | swfw-modules bootstrap uses Azure File Share with file uploads — corporate SSL proxy blocks this. Our base64-into-custom_data approach via IMDS is officially supported by PAN-OS 10.0+ and works in this environment |
| `modules/routing` (~180 LOC) | (no equivalent) | **KEEP** | UDR table logic is Azure-specific, not VM-Series-specific |
| `modules/frontdoor` (~190 LOC) | (no equivalent) | **KEEP** | PANW does not publish an Azure Front Door module |
| `modules/spoke1_app`, `modules/spoke2_dc` | partial (`test_infrastructure`) | **KEEP** | Custom workloads (Apache HTTP, Windows DC) — not generalisable |
| `modules/panorama_config` (~900 LOC after B1+D1+D3) | (none — config, not infrastructure) | **KEEP** | panos provider resources + XML API; no infra equivalent |

**Net effect of partial migration:** ~1,500 LOC reduction (~47% of azurerm code),
better-tested networking + LB code, while retaining battle-tested bootstrap + HA
+ Panorama config + AFD that solve problems generic modules don't.

## Migration order (lowest risk first)

Each step in its own branch + PR. Run `terraform plan` against a dev environment
between steps; if anything other than the expected resources moves in state, roll
back.

1. **`vnet` + `vnet_peering`** — pure infrastructure, no HA implications.
   Largest LOC win. Low risk.
2. **`loadbalancer`** — Standard LB resources only. Health probes + HA Ports
   rule must match current behaviour exactly (floating IP enabled on external
   rules is load-bearing for PAN-OS DNAT — verify swfw-modules exposes this).
3. **`panorama`** — single VM swap. Brief downtime acceptable since Panorama
   isn't on the data path; FWs operate independently.
4. **`vmseries`** — highest-risk step. VM swap triggers Azure LB backend
   re-evaluation; failover happens during the switch. Maintenance window
   recommended. Keep `null_resource.fw_set_userdata` as a wrapper around the
   swfw-modules `vmseries` resource if the official module also lacks
   `user_data` propagation for marketplace VMs (test first).

## Things that block "full" migration

- **Bootstrap via File Share** — the swfw-modules `bootstrap` module uploads
  init-cfg.txt + authcodes to Azure File Share. The Terraform Go HTTP client and
  `curl` both fail with "connection reset" against `*.file.core.windows.net` in
  environments with corporate SSL inspection. Our custom module sidesteps this
  by base64-encoding init-cfg into `custom_data`/`userData` (read by PAN-OS via
  IMDS — officially supported). Do NOT replace this module unless deployment
  moves to an environment without that proxy.
- **Multi-VR architecture** in `modules/panorama_config/main.tf` (VR-External +
  VR-Internal) — required for Azure LB sandwich topology so both External and
  Internal LB health probes (source `168.63.129.16`) get symmetric return paths.
  swfw-modules examples assume single VR; ours intentionally diverges. Keep.
- **Front Door** — added on top of External LB for global L7, WAF and DDoS.
  PANW does not publish an AFD module. Keep custom.

## Operational pre-flight before starting v2

- [ ] Verify `azurerm` 4.x changelog for `user_data` propagation fix on
      marketplace VMs with `plan{}` block. If fixed, `null_resource.fw_set_userdata`
      can be dropped (see TODO comment in `modules/firewall/main.tf`).
- [ ] Confirm that swfw-modules `vmseries` example for transit-vnet-common still
      uses Active/Passive HA with HA Ports on internal LB (rather than newer
      VMSS / Gateway LB patterns).
- [ ] Re-read PANW deployment guide
      `docs/reference/pdfs/securing-apps-azure-vmseries-panorama.pdf` chapter
      "Deploying VPN to Prisma Access" if remote-access scope is added.

---

# v3 – Panorama Orchestrated Deployment in Azure (evaluation only — NOT planned)

**Status:** Forward-looking placeholder. v2 (partial swfw-modules adoption) does
NOT depend on this. Document captured here so the comparison is on record when
the question comes up again.

## What "Panorama Orchestrated" actually means

PANW uses this term for a deployment model built around the **Panorama Plugin
for Azure** rather than around Terraform azurerm + manual FW registration:

- Plugin runs on Panorama, authenticated to the Azure subscription via a
  managed identity with `Reader` (and optionally `Contributor`) role.
- Panorama auto-discovers VM-Series instances in the subscription, optionally
  filtered by Resource Group, region, or VM tags.
- Bootstrap is centralised: FW pulls config from Panorama directly over HTTPS
  rather than reading init-cfg from Azure custom_data / IMDS. No vm-auth-key
  shuffling — FW identity is established via Azure metadata signed by the
  Azure platform.
- Typical pairing: VM Scale Set (VMSS) with autoscale rules, NOT a static
  Active/Passive HA pair. Panorama tracks scale-out / scale-in events.
- Tagging propagates from Azure (resource tags) into Panorama Dynamic Address
  Groups automatically — useful for "isolate any VM tagged `compromised=true`"
  patterns.

## How v3 differs from current (v1) and v2

| Concern | v1 (today) | v2 (partial swfw-modules) | v3 (Panorama Orchestrated) |
|---|---|---|---|
| FW provisioning | Custom `modules/firewall` | swfw-modules `vmseries` (per #4 above) | VMSS + Panorama Plugin lifecycle hooks |
| Bootstrap | init-cfg via custom_data + IMDS | Same | Panorama-pulled config (no init-cfg files) |
| FW serial registration | `scripts/register-fw-panorama.sh` (SSH + XML API) | Same | Auto via plugin Azure-discovery |
| HA model | Active/Passive pair behind LB HA Ports | Same | VMSS + LB (no PAN-OS HA pair, scale events instead of failover) |
| Tag-driven policy | None | None | Azure tags → Dynamic Address Groups (automatic) |
| Operational complexity | Higher (manual ops) | Same | Lower at steady state, higher upfront (plugin install, RBAC, plugin upgrade flow) |
| Suitable for | Lab / fixed prod pair | Lab / fixed prod pair (cleaner code) | Production at scale, autoscale, multi-region, tag-driven micro-segmentation |

## Why v3 is NOT the v2 direction

1. **Different problem class.** This project's current workload (one transit
   VNet, fixed FW pair, lab/POC) does not need autoscale or auto-discovery.
   Panorama Orchestrated optimises for the case we don't have.
2. **Loss of fine-grained control.** Plugin-driven bootstrap takes init-cfg
   choices out of Terraform's hands — harder to enforce specific PAN-OS
   versions / panorama-server / dns-primary deviations per FW.
3. **VMSS + autoscale is a separate refactor.** Switching from fixed pair to
   VMSS replaces `modules/firewall` wholesale, not in pieces. This makes v3
   a *rewrite*, not an *evolution*.
4. **Plugin lifecycle dependency.** Panorama Plugin for Azure has its own
   release cadence + compatibility matrix vs PAN-OS. Adds another moving
   part to upgrade planning.

## When v3 evaluation should be reopened

- If/when this project is extended to a production workload that needs:
  - Autoscaling firewalls (VMSS) for variable traffic patterns
  - Multi-region deployment with shared Panorama
  - Tag-driven micro-segmentation (Azure tags → DAGs)
- OR if PANW deprecates the current init-cfg + vm-auth-key flow in a future
  PAN-OS major version (currently no signal of this).

## References to consult before starting v3

- Panorama Plugin for Azure docs: <https://docs.paloaltonetworks.com/plugins/panorama-plugins/azure>
- PANW VM-Series in Azure VMSS reference: <https://github.com/PaloAltoNetworks/azure-autoscaling>
- This project's local PDF library: see `pdfs/securing-apps-azure-vmseries-panorama.pdf`
  Chapter on Panorama Plugin (verify section title in current edition).
- The "Azure Architecture Guide" landing page —
  <https://www.paloaltonetworks.com/resources/guides/azure-architecture-guide> —
  serves the same PDF as `pdfs/securing-apps-azure-design-guide.pdf` in this
  project, useful as a freshness check / version provenance.
