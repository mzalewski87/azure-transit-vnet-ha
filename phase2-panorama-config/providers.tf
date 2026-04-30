###############################################################################
# Phase 2 – Panorama Configuration via panos provider
#
# The panos provider connects to Panorama via an active Bastion Tunnel.
# Panorama does NOT have a public IP – access is only via the Spoke2 Bastion.
#
# STEP 1 (terminal 1) – start an HTTPS tunnel to Panorama (leave it open):
#   PANORAMA_ID=$(cd .. && terraform output -raw panorama_vm_id)
#   az network bastion tunnel \
#     --name bastion-spoke2 \
#     --resource-group rg-spoke2-dc \
#     --target-resource-id "$PANORAMA_ID" \
#     --resource-port 443 \
#     --port 44300
#
# NOTE: --target-resource-id (not --target-ip-address) because of port 443
#   IpConnect only allows ports 22 and 3389.
#   Tunneling via --target-resource-id has no port restrictions.
#
# STEP 2 (terminal 2) – start Phase 2 (the tunnel must be active):
#   cd phase2-panorama-config/
#   cp terraform.tfvars.example terraform.tfvars
#   # Set: panorama_hostname = "127.0.0.1", panorama_port = 44300
#   terraform init && terraform apply
###############################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    panos = {
      source  = "PaloAltoNetworks/panos"
      version = "~> 1.11"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

# The panos provider connects via the local Bastion tunnel (127.0.0.1:44300).
# Default panos timeout is 10s; we extend to 180s because:
#   - Bastion tunnel adds ~1-2s of latency per request
#   - Panorama may still be processing background commits (commit-all on the
#     Collector Group, license activation restart) when the first panos call
#     arrives — those hold a config lock that panos has to wait on
#   - 60s previously was not enough; 180s covers a full commit cycle worst-case
# null_resource.panorama_wait_jobs_idle in main.tf also blocks until pending
# Panorama jobs finish, but timeout=180 gives the actual API call breathing room.
provider "panos" {
  hostname = var.panorama_hostname # 127.0.0.1
  port     = var.panorama_port     # 44300 (match --port from az bastion tunnel)
  username = var.panorama_username
  password = var.panorama_password
  timeout  = 180
}
