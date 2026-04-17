###############################################################################
# Phase 2 – Panorama Configuration
# Osobny katalog Terraform z providerem panos
#
# ⚠️  WYMÓG: Panorama NIE ma publicznego IP!
#    Provider panos łączy się przez AKTYWNY Azure Bastion Tunnel:
#
#    KROK 1 (terminal 1) – uruchom tunel i zostaw działający:
#      az network bastion tunnel \
#        --name bastion-hub \
#        --resource-group rg-transit-hub \
#        --target-ip-address 10.0.0.10 \
#        --resource-port 443 \
#        --port 44300
#      # lub użyj skryptu: ../scripts/check-panorama.sh
#
#    KROK 2 (terminal 2) – deploy phase 2 (tunel musi być aktywny!):
#      cd phase2-panorama-config/
#      cp terraform.tfvars.example terraform.tfvars
#      # Ustaw panorama_hostname = "127.0.0.1", panorama_port = 44300
#      terraform init
#      terraform apply
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

# Provider panos – łączy się przez lokalny tunel Bastion (127.0.0.1:port)
# panorama_hostname = "127.0.0.1" gdy używasz az network bastion tunnel
# panorama_port     = 44300       (lokalny port tunelu)
provider "panos" {
  hostname = var.panorama_hostname  # 127.0.0.1 gdy przez Bastion tunnel
  port     = var.panorama_port      # 44300 (match --port w az bastion tunnel)
  username = var.panorama_username
  password = var.panorama_password
}
