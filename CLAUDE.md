# Project guidance for Claude Code (and other AI assistants)

This is a Terraform IaC project deploying a Palo Alto Networks VM-Series
Active/Passive HA pair in Azure (transit VNet topology, managed by self-hosted
Panorama). Read this file first when starting work on this repo — it surfaces
the load-bearing design decisions that are easy to break by accident.

## Repo role: source of truth, not a deploy target

This local repo (`/Users/mzalewski/TF/azure_ha_project`) is the **source** that
gets pushed to `origin/main` (https://github.com/mzalewski87/azure-transit-vnet-ha).
Actual `terraform apply` runs against a **separate clone** in another directory
that the user pulls from origin. Do not run `terraform apply` here. Limit
yourself to `terraform validate`, `terraform fmt -check`, and code edits.

## Phased deployment — what runs where

Deployment is intentionally split across 5 phases, NOT a single `terraform
apply`. The split is load-bearing — see `docs/ROADMAP-swfw-modules-migration.md`
and the architecture overview in README.

- **Phase 1a** (root, `-target` apply): RGs, networking, bootstrap, panorama VM
- **Phase 2a** (`cd phase2-panorama-config && terraform apply`): a SEPARATE
  workspace — uses the `panos` provider which connects to Panorama on every
  `plan`. Keeping it in root would block all plans until Panorama is up
  (~15 min boot). This is the load-bearing reason for the split.
  Auto-generates `vm-auth-key` and writes `../panorama_vm_auth_key.auto.tfvars`
  consumed by Phase 1b.
- **Phase 1b** (root, `-target` apply): loadbalancer + firewall + routing +
  frontdoor + spoke1_app
- **Phase 2b** (`bash scripts/register-fw-panorama.sh`): registers FW serials
  on Panorama via Bastion tunnel, pushes Template + DG to FWs
- **Phase 3** (`-target=module.app2_dc` + `optional/dc-promote/`)

## Bootstrap pattern — why we do NOT use swfw-modules `bootstrap`

We use a custom `modules/bootstrap/` that base64-encodes `init-cfg.txt` into
Azure VM `custom_data` / `userData`, read by PAN-OS via IMDS at boot. This is
officially supported by PAN-OS 10.0+.

We deliberately do NOT use the official `PaloAltoNetworks/swfw-modules/azurerm/bootstrap`
sub-module because it uploads files to Azure File Share via PUT-with-body, and
the user's environment runs corporate SSL inspection that blocks `*.file.core.windows.net`
PUTs (both Terraform Go client and curl fail with "connection reset"). Full
reasoning in `docs/ROADMAP-swfw-modules-migration.md` § "Things that block full migration".

If you find yourself proposing to "simplify" by adopting swfw-modules `bootstrap` —
re-read the ROADMAP first.

## Load-bearing details (easy to break by accident)

- **External LB rules: `enable_floating_ip = true`** — required for PAN-OS DNAT
  to match the destination IP correctly. Removing it breaks inbound traffic.
- **`null_resource.fw_set_userdata`** in `modules/firewall/main.tf` does
  `az vm deallocate → az vm update --user-data → az vm start` because azurerm
  historically did not propagate `user_data` for marketplace VMs with `plan{}`
  blocks. Pre-flight checklist in ROADMAP says retest on azurerm 4.x before
  removing.
- **Multi-VR architecture** in `modules/panorama_config/main.tf` (VR-External +
  VR-Internal) — required for Azure LB sandwich so both External and Internal
  LB health probes (source `168.63.129.16`) get symmetric return paths.
  swfw-modules examples assume single VR; ours intentionally diverges.
- **Internal LB uses HA Ports rule** (protocol=All, port=0) — only valid on
  internal LBs, not external (Azure restriction). Don't try to "unify".
- **`time_sleep.wait_for_sa_network_rules` (60s)** in bootstrap module is a
  workaround for Azure's eventually-consistent network-rule propagation on
  Storage Accounts. Don't remove without verifying the race is fixed.
- **Phase 2a writes `panorama_vm_auth_key.auto.tfvars`** — Phase 1b auto-loads
  it. This implicit cross-workspace handoff is real.
- **Log Collector setup** has SIX load-bearing pieces (after 2026-05-07 fixes):
  (1) local Panorama LC bound to default Collector Group, (2) dedicated
  `commit-all log-collector-config` push to LC daemon, (3) system-level
  log forwarding match-list under `/config/shared/log-settings/<TYPE>` in
  Template, (4) **disk-pair declaration** under `.../log-collector/entry/disk-settings/disk-pair`,
  (5) **DLF entries** under `.../log-collector-group/entry/logfwd-setting/devices`
  binding each FW serial to the LC, (6) **Panorama restart after disk-pair
  add** — PAN-OS 12.1.5 does not auto-reinit ES indices when disk-pair is
  added at runtime, so log queries return 0 even with thousands of received
  logs persisted to disk; only a reboot rebuilds the indices (Step 4b3,
  `null_resource.panorama_restart_for_es_reinit`, ~8-13 min). All six are
  automated in Phase 2a/2b. See
  `~/.claude/projects/-Users-mzalewski-TF-azure-ha-project/memory/panorama_log_collector.md`
  for the empirically-verified xpaths, CLI commit-all keyword quirks, and
  the discovery method (`debug cli on` per pan-os-panorama-api.pdf p.25).

## Where to look for context

- **`docs/reference/pdfs/INDEX.md`** — catalogue of all PDFs by priority (P0–P4)
  with one-line summaries scoped to this project. Read this before reading any
  PDF; the big ones (panorama-admin.pdf 53 MB, vm-series-deployment.pdf 92 MB)
  are lookup-only, never end-to-end.
- **`docs/reference/links.md`** — sectioned URL list (PANW portal, Azure docs,
  Terraform providers/modules, GitHub repos).
- **`docs/ROADMAP-swfw-modules-migration.md`** — what's deferred to v2 (partial
  swfw-modules adoption) and v3 (Panorama Orchestrated Deployment evaluation,
  intentionally NOT planned). Read before proposing module-level rewrites.
- **`README.md`** — user-facing deployment instructions, troubleshooting,
  Phase 2 mechanism reference.

## Conventions

- **Conventional Commits**: `fix(scope): subject`, `feat(scope): subject`,
  `docs:`, `chore:`, `refactor:`. Multi-paragraph body with **why** (not what
  — diff shows what). Each commit ends with `Co-Authored-By: Claude ...` line.
- **Languages**: Polish in chat, English in code/docs/commits. The user reads
  Polish responses faster but ships English to the repo.
- **Validate before commit**: `terraform validate` on root AND
  `phase2-panorama-config/`. Both must pass.
- **Don't auto-push without confirmation** unless the current commit is small
  and the user has authorised that scope.

## Don'ts (per user feedback / safety rails)

- Don't `git push --force` to main (and warn the user if they ask for it).
- Don't `git commit --no-verify` to skip pre-commit hooks unless explicitly
  asked. Fix the underlying issue instead.
- Don't `git commit --amend` on an already-pushed commit. Create a new commit
  with the correction.
- Don't propose adopting swfw-modules `bootstrap` (re-read the ROADMAP first
  if tempted — it is incompatible with this environment).
- Don't run destructive operations on the local working tree (rm of files
  with uncommitted changes, `git reset --hard` past a commit) without flagging
  the cost first.
