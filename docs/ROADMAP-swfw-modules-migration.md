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
