# Reference Documentation – Links

URL references for project documentation: PANW, Microsoft Azure, Terraform,
blogs, GitHub repos. Group by section. One bullet per entry.

---

## 1. Palo Alto Networks – Azure Transit VNet / VM-Series Reference Architecture

- **PANW Reference Architectures portal** — <https://www.paloaltonetworks.com/referencearchitectures>
  - Master index of all PANW reference-architecture guides (overview / design / deployment / solution).

- **Azure Transit VNet Deployment Guide (legacy direct link)** — <https://www.paloaltonetworks.com/apps/pan/public/downloadResource?pagePath=/content/pan/en_US/resources/guides/azure-transit-vnet-deployment-guide>
  - Older version of the deployment guide. Newer "Securing Applications in Azure
    with VM-Series Firewalls and Panorama" PDF (DEC 2024) supersedes it.

---

## 2. Palo Alto Networks – Community / Forums

- **PANW LIVEcommunity – Azure** — <https://live.paloaltonetworks.com/t5/azure/ct-p/Azure>
- **PANW LIVEcommunity – Panorama** — <https://live.paloaltonetworks.com/t5/panorama/ct-p/Panorama>
- **PANW LIVEcommunity – VM-Series in Public Cloud** — <https://live.paloaltonetworks.com/t5/vm-series-in-the-public-cloud/bd-p/AWS_Azure_Discussions>

---

## 3. Microsoft Azure – Networking / Bastion / Front Door / vWAN

<!-- ADD: Azure docs, ARM/Bicep references, troubleshooting threads -->

---

## 4. Terraform Providers (panos, scm, azurerm)

- **panos provider** — <https://registry.terraform.io/providers/PaloAltoNetworks/panos/latest>
  - Official PAN-OS / Panorama provider. Project pins `~> 1.11`.
- **scm provider** — <https://registry.terraform.io/providers/PaloAltoNetworks/scm/latest>
  - Strata Cloud Manager provider (cloud-managed PAN-OS). Not used in this
    self-managed Panorama setup.

---

## 5. Terraform Modules – Official PANW

- **swfw-modules / azurerm (modern)** — <https://registry.terraform.io/modules/PaloAltoNetworks/swfw-modules/azurerm/latest>
  - See `docs/ROADMAP-swfw-modules-migration.md` for the v2 migration plan.
- **vmseries-modules / azurerm (legacy)** — <https://registry.terraform.io/modules/PaloAltoNetworks/vmseries-modules/azurerm/latest>
  - Older predecessor of swfw-modules.
- **panos-bootstrap / azurerm (deprecated)** — <https://registry.terraform.io/modules/PaloAltoNetworks/panos-bootstrap/azurerm/latest>
  - Direct equivalent of `modules/bootstrap/`. Uses Azure File Share — incompatible
    with corporate SSL inspection environments. Our custom module sidesteps this
    by base64-encoding init-cfg into custom_data + IMDS.
- **panorama-onboarding / cloudngfw** — <https://registry.terraform.io/modules/PaloAltoNetworks/panorama-onboarding/cloudngfw/latest>
  - Cloud-NGFW oriented. Not applicable to this self-hosted Panorama.
- **ngfw-modules / panos** — <https://registry.terraform.io/modules/PaloAltoNetworks/ngfw-modules/panos/latest>
  - panos-provider modules for NGFW config (zones, policies). Possibly useful
    for replacing Phase 2 panos resources.

---

## 6. PANW Reference Implementations / Examples (GitHub)

- <https://github.com/PaloAltoNetworks/terraform-azurerm-swfw-modules> — modern Azure modules (source of #5 above)
- <https://github.com/PaloAltoNetworks/terraform-azurerm-vmseries-modules> — legacy predecessor
- <https://github.com/PaloAltoNetworks/terraform-azurerm-panos-bootstrap> — bootstrap module source
- <https://github.com/PaloAltoNetworks/Azure-Transit-VNet> — older transit-VNet implementation (ARM/PowerShell)
- <https://github.com/PaloAltoNetworks/Azure-HA-Deployment> — HA pattern reference
- <https://github.com/PaloAltoNetworks/Azure-HA-AutoLaunch> — HA auto-launch variant
- <https://github.com/PaloAltoNetworks/azure-terraform-vmseries-fast-ha-failover> — accelerated failover (UDR rewrites)
- <https://github.com/PaloAltoNetworks/Azure-OutboundHA-StandardLB> — outbound HA with Standard LB
- <https://github.com/PaloAltoNetworks/Azure-GWLB> — Gateway Load Balancer pattern
- <https://github.com/PaloAltoNetworks/microsoft_azure_virtual_wan> — vWAN integration pattern
- <https://github.com/PaloAltoNetworks/azure-availability-zone> — zone-aware HA pattern
- <https://github.com/PaloAltoNetworks/azure-autoscaling> — autoscaling group pattern
- <https://github.com/PaloAltoNetworks/azure-applicationgateway> — App Gateway as inbound option
- <https://github.com/PaloAltoNetworks/lab-azure-vmseries> — lab/demo deployment
- <https://github.com/PaloAltoNetworks/azure-aks> — AKS integration
- <https://github.com/PaloAltoNetworks/azure-vm-monitoring> — monitoring pattern
- <https://github.com/PaloAltoNetworks/azure> — generic Azure landing page
- <https://github.com/PaloAltoNetworks/terraform-templates> — generic Terraform examples
- <https://github.com/PaloAltoNetworks/Azure-Resource-Cleanup-Tool> — cleanup tooling

---

## 7. Other (blogs, videos, troubleshooting threads)

<!-- ADD as discovered -->

---

## 8. Local PDF Library Index

See `pdfs/INDEX.md` for the catalogue of PDFs (priority + one-line summary).
The PDFs themselves are vendor-copyrighted and gitignored — pull them locally
from PANW Reference Architectures portal as needed.
