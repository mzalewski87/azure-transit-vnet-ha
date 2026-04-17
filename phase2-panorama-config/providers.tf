###############################################################################
# Phase 2 – Panorama Configuration via panos provider
#
# Provider panos laczy sie z Panorama przez aktywny Bastion Tunnel.
# Panorama NIE ma publicznego IP – dostep tylko przez Spoke2 Bastion.
#
# KROK 1 (terminal 1) – uruchom tunel HTTPS do Panoramy (pozostaw otwarty):
#   PANORAMA_ID=$(cd .. && terraform output -raw panorama_vm_id)
#   az network bastion tunnel \
#     --name bastion-spoke2 \
#     --resource-group rg-spoke2-dc \
#     --target-resource-id "$PANORAMA_ID" \
#     --resource-port 443 \
#     --port 44300
#
# UWAGA: --target-resource-id (nie --target-ip-address) bo port 443
#   IpConnect dozwala tylko portow 22 i 3389.
#   Tunneling przez --target-resource-id nie ma ograniczen portow.
#
# KROK 2 (terminal 2) – uruchom Phase 2 (tunel musi byc aktywny):
#   cd phase2-panorama-config/
#   cp terraform.tfvars.example terraform.tfvars
#   # Ustaw: panorama_hostname = "127.0.0.1", panorama_port = 44300
#   terraform init && terraform apply
###############################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    panos = {
      source  = "PaloAltoNetworks/panos"
      version = "~> 1.11"
    }
  }
}

# Provider panos laczy sie przez lokalny tunel Bastion (127.0.0.1:44300)
provider "panos" {
  hostname = var.panorama_hostname  # 127.0.0.1
  port     = var.panorama_port      # 44300 (match --port w az bastion tunnel)
  username = var.panorama_username
  password = var.panorama_password
}
