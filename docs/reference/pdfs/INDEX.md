# PDF Library – Index

Catalogue of all PDFs in this directory, grouped by relevance to **this project**:
Active/Passive VM-Series HA in Azure, transit VNet, behind Standard LB + Front Door,
managed by self-hosted Panorama. Use this index to pick the right doc fast.

Read-priority key:
- **P0** — primary reference for the refactor; read in full
- **P1** — high-value, sectioned reading (best practices applicable to this design)
- **P2** — reference / lookup; read only the relevant chapter
- **P3** — alternative architecture or future scope; background only
- **P4** — out of scope for current project (subscription service / different product)

---

## P0 — PRIMARY DEPLOYMENT REFERENCES (read in full)

| File | Size | Pages | Notes |
|---|---|---|---|
| `securing-apps-azure-vmseries-panorama.pdf` | 8.1 MB | 132 | **THE deployment guide for our architecture** (DEC 2024). Transit VNet + HA + Panorama. Covers Outbound, East-West, Inbound (Public LB OR App Gateway), Panorama Templates/Stacks/DGs, bootstrap, post-deploy config. Pages 114–132 (Prisma Access VPN) are out of scope for us. |
| `securing-apps-azure-design-guide.pdf` | 4.7 MB | — | Companion design guide to the above. Architectural rationale, topology, HA failover logic, NSG/UDR design. Required reading **before** the deployment guide per PANW's guide-types convention. |

## P1 — BEST PRACTICES (high-value for refactor scope)

| File | Size | Notes |
|---|---|---|
| `best-practices-for-managing-firewalls-with-panorama.pdf` | 1.5 MB | Template stack hierarchy, device-group inheritance, log forwarding patterns. **Highly applicable** — current `phase2-panorama-config/` uses a single template + single DG; multi-tier hierarchy would scale better. |
| `security-policy-best-practices.pdf` | 1.8 MB | Application-aware rules, session logging on allow+deny, periodic rule audit. Current policies are coarse (Allow-Trust-to-Untrust). |
| `administrative-access-best-practices.pdf` | 1.7 MB | RBAC, MFA on Panorama, admin audit log forwarding. Current setup uses single `panadmin` superuser — **gap**. |
| `dos-and-zone-protection-best-practices.pdf` | 1.6 MB | Zone Protection Profiles (SYN flood, port scan, etc.) on untrust/trust zones. **Not configured** in current Phase 2 — recommended addition. |
| `zero-trust-best-practices.pdf` | 1.7 MB | Identity-based segmentation, micro-perimeters. Aspirational for this project but informs future direction. |
| `decryption-best-practices.pdf` | 1.5 MB | SSL decryption policy scoping, certificate distribution. **Not used** in current setup; relevant if we add inspection of HTTPS traffic. |
| `user-id-best-practices.pdf` | 1.5 MB | User-ID + Azure AD integration. Pre-requisite for any zero-trust extension. |

## P2 — DEEP REFERENCE (lookup-only, do not read end-to-end)

| File | Size | Notes |
|---|---|---|
| `panorama-admin.pdf` | 53 MB | Panorama Administrator's Guide. **Massive.** Use as lookup for specific Panorama features (Collector Groups, Log Forwarding, HA, Templates, Device Groups). |
| `vm-series-deployment.pdf` | 92 MB | VM-Series Deployment Guide (all clouds). **Massive.** Reference for PAN-OS-on-VM specifics: bootstrap formats, init-cfg parameters, IMDS, license activation, HA configuration. |
| `getting-started.pdf` | 1.7 MB | PAN-OS Getting Started — basics of policy, NAT, interfaces, VRs. Refresh material. |
| `pan-os-upgrade.pdf` | 7.5 MB | PAN-OS upgrade procedures. Relevant for Day-2 ops planning. |
| `pan-os-upgrade (1).pdf` | 6.9 MB | Likely older version of above (different size). Consider deleting one after diff. |
| `compatibility-matrix-reference.pdf` | 3.1 MB | PAN-OS / Panorama / VM-Series version compatibility matrix. Lookup before pinning versions. |
| `activation-and-onboarding.pdf` | 1.5 MB | Customer Support Portal (CSP) auth code + license activation flow. |
| `subscription-and-tenant-management.pdf` | 6.8 MB | CSP tenant + subscription management. |

## P3 — ALTERNATIVE ARCHITECTURES (background / future scope)

| File | Size | Notes |
|---|---|---|
| `securing-microsoft-azure-vwan-solution-guide.pdf` | 5.9 MB | Azure Virtual WAN as alternative to classic transit VNet. **Not our pattern** but useful comparison if we later expand to multi-region or multi-branch. |
| `sec-apps-azure-using-service-connections.pdf` | 3.1 MB | Prisma Access service connections into Azure (SASE remote access). Out of current scope. |
| `network-security-for-public-cloud-overview.pdf` | 2.7 MB | High-level conceptual overview (shared responsibility, NGFW value-prop). Stakeholder/exec-deck material rather than design input. |

## P4 — OUT OF SCOPE FOR CURRENT PROJECT

These cover PANW subscription services and adjacent products NOT used in the current architecture.
Keep for reference if/when we extend the project.

| File | Size | Why out of scope |
|---|---|---|
| `advanced-threat-prevention-administration.pdf` | 4.5 MB | ATP subscription not in current FW config |
| `advanced-url-filtering-administration.pdf` | 6.8 MB | URL Filtering subscription not configured |
| `advanced-wildfire-administration.pdf` | 3.7 MB | WildFire subscription not configured |
| `dns-security-administration.pdf` | 4.7 MB | DNS Security subscription not configured |
| `enterprise-dlp-administration.pdf` | 36 MB | DLP subscription — out of scope |
| `getting-started-atp.pdf` | 2.4 MB | Companion to ATP doc above |
| `getting-started-enterprise-dlp.pdf` | 3.5 MB | Companion to DLP doc above |
| `getting-started-sspm.pdf` | 5.2 MB | SaaS Security Posture Mgmt — different product |
| `identity-cloud-identity-engine.pdf` | 88 MB | Cloud Identity Engine — relevant only with User-ID / ZTNA extension |
| `identity-activation-and-onboarding.pdf` | 2.6 MB | Companion to CIE above |
| `iot-security-activation-and-onboarding.pdf` | 2.6 MB | IoT Security — different product |
| `iot-security-administration.pdf` | 16 MB | Companion to above |
