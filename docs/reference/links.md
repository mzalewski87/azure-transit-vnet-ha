# Reference Documentation – Links

URL references for project documentation: PANW, Microsoft Azure, Terraform,
blogs, GitHub repos. Group by section. One bullet per entry.

---

## 1. Palo Alto Networks – Azure Transit VNet / VM-Series Reference Architecture

- **PANW Reference Architectures portal** — <https://www.paloaltonetworks.com/referencearchitectures>
  - Master index of all PANW reference-architecture guides (overview / design / deployment / solution).

- **Azure Architecture Guide (landing page)** — <https://www.paloaltonetworks.com/resources/guides/azure-architecture-guide>
  - Direct PDF download: <https://www.paloaltonetworks.com/apps/pan/public/downloadResource?pagePath=/content/pan/en_US/resources/guides/azure-architecture-guide>
  - **Serves the SAME file** as `pdfs/securing-apps-azure-design-guide.pdf` (verified
    2026-05-05 by Content-Length match). The portal exposes it under multiple
    URLs / titles. Use this URL as the freshness check (compare Content-Length
    or download date with the local copy when refreshing references).

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

## 3a. Microsoft Azure – Azure Kubernetes Service (AKS)

Relevant for `optional/aks-deploy/` — AKS cluster, egress rules, networking.

- **AKS outbound rules / egress control** — <https://learn.microsoft.com/en-us/azure/aks/outbound-rules-control-egress>
  - **Source of truth** for AKS egress FQDNs and IP/port requirements. Consumed by
    `optional/aks-deploy/modules/edl_server/files/fqdn_base_list.txt` (hardcoded
    fallback list). Re-read this page when refreshing the EDL baseline.

- **AKS quickstart (CLI)** — <https://learn.microsoft.com/en-us/azure/aks/learn/quick-kubernetes-deploy-cli>
  - Walks through `az aks create` + sample app deploy. Useful reference; the
    `optional/aks-deploy/` module supersedes the imperative az CLI flow.

- **Azure CNI Overlay networking** — <https://learn.microsoft.com/en-us/azure/aks/concepts-network-azure-cni-overlay>
  - Why we use overlay: pods get IPs from a non-VNet `pod_cidr` (10.244.0.0/16)
    instead of consuming VNet subnet IPs. Node IPs come from `snet-aks-nodes`.

- **AKS userDefinedRouting outbound type** — <https://learn.microsoft.com/en-us/azure/aks/limit-egress-traffic>
  - The `outbound_type=userDefinedRouting` mode we use to force AKS egress through
    the VM-Series firewalls via UDR → ILB → FW. Without UDR + this setting AKS
    would create its own public LB and bypass the firewalls.

- **AKS Bring-your-own-VNet** — <https://learn.microsoft.com/en-us/azure/aks/configure-azure-cni>
  - How to deploy AKS into an existing VNet/subnet (our spoke3 pattern).

- **Bitnami WordPress Helm chart** — <https://github.com/bitnami/charts/tree/main/bitnami/wordpress>
  - The Helm chart used for the sample WordPress workload. Includes MariaDB
    sub-chart by default. Values reference for the `helm_release.wordpress`
    resource.

- **Bitnami ingress-nginx chart** — <https://kubernetes.github.io/ingress-nginx/>
  - Ingress controller (LoadBalancer service type) we install via Helm to expose
    WordPress to the AKS internal LB.

---

## 3b. Microsoft Azure – Service Tags / IP Ranges

Relevant for the dynamic IP EDL generator in `optional/aks-deploy/modules/edl_server/`.

- **Azure IP Ranges and Service Tags – Public Cloud (weekly JSON)** — <https://www.microsoft.com/en-us/download/details.aspx?id=56519>
  - Microsoft publishes the JSON weekly. URL on the page changes every refresh —
    `generate_aks_edl.py` scrapes the confirmation page to discover the current
    JSON URL, then extracts `AzureCloud.<region>` IP prefixes for the IP EDL.

- **Service Tag Discovery REST API** — <https://learn.microsoft.com/en-us/rest/api/virtualnetwork/service-tags/list>
  - Alternative source if the JSON download path fails. Requires an Azure AD
    token (Managed Identity on the EDL server VM could be configured later).

- **Using Azure IP Ranges and Service Tags (blog, J. Mattila)** — <https://www.jannemattila.com/azure/2024/01/22/using-azure-ip-ranges-and-service-tags.html>
  - Background reading: scraping pattern + JSON structure.

---

## 3c. Palo Alto Networks – External Dynamic Lists (EDL)

Relevant for `modules/panorama_aks_rules/` and `modules/edl_server/`.

- **EDL — concept and policy use** — <https://docs.paloaltonetworks.com/pan-os/11-0/pan-os-admin/policy/use-an-external-dynamic-list-in-policy/external-dynamic-list>
- **EDL — formatting guidelines** — <https://docs.paloaltonetworks.com/pan-os/10-1/pan-os-admin/policy/use-an-external-dynamic-list-in-policy/formatting-guidelines-for-an-external-dynamic-list>
  - **Critical:** URL list entries with wildcards need a trailing slash
    (`*.example.com/`). Without the slash the match silently fails.
- **PAN-OS support for wildcard FQDN in EDL (Reddit thread)** — <https://www.reddit.com/r/paloaltonetworks/comments/1p5oj65/does_external_dynamic_lists_support_wild_card/>
  - URL EDL supports wildcards; Domain EDL does NOT. We use URL EDL for AKS
    wildcards like `*.hcp.<region>.azmk8s.io/`.

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
