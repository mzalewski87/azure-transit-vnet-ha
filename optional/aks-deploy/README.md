# Optional: AKS + WordPress Deployment

Standalone Terraform workspace that adds:

- **New AKS spoke** (spoke3 VNet, 10.114.0.0/16) peered with the existing transit hub
- **AKS cluster** with Azure CNI Overlay + `outbound_type=userDefinedRouting` (all egress through VM-Series FWs)
- **WordPress** via Bitnami Helm chart (with bundled MariaDB) + ingress-nginx
- **Custom EDL server** (Ubuntu+nginx+Python generator) in the management VNet — serves AKS egress allowlist to Panorama
- **Panorama rules** (2 EDL objects, 3 security rules, 1 NAT rule) pushed automatically to FWs
- **New Front Door endpoint** under the existing `afd-panos-transit` profile + new External LB rule on port 8080

Everything is deployed with **one `terraform apply`** (~25-35 min). Destroy reverses cleanly.

See:
- [`docs/aks-runbook.md`](../../docs/aks-runbook.md) for step-by-step deployment + troubleshooting
- [`docs/aks-rules-structure.md`](../../docs/aks-rules-structure.md) for EDL anatomy + rule design rationale
- `terraform.tfvars.example` for required inputs

## Prerequisites

1. **Root module fully deployed** (Phase 1a + 1b + 2a + 2b done) — see root `README.md`
2. **Bastion tunnel to Panorama** running on `127.0.0.1:44300` — see `terraform.tfvars.example` for the `az network bastion tunnel` command
3. **`kubectl` and `az` CLI installed locally** — `terraform apply` invokes them for smoke tests

## Quick start

```bash
cp terraform.tfvars.example terraform.tfvars
# Fill in REPLACE_ME values

# Start the Bastion tunnel (separate terminal — leave it open)
PANORAMA_ID=$(cd ../.. && terraform output -raw panorama_vm_id)
az network bastion tunnel \
  --name bastion-management \
  --resource-group rg-transit-hub \
  --target-resource-id "$PANORAMA_ID" \
  --resource-port 443 \
  --port 44300

# Apply (in this directory)
terraform init
terraform apply
```

After ~25-35 min, the output `wordpress_url` is the public address. Open it in a browser.

## Teardown

```bash
terraform destroy
```

Destroy proceeds in reverse order: smoke tests → AFD/LB rule → WordPress (Helm) → AKS → Panorama rules → spoke3 → EDL. The root module is untouched.
