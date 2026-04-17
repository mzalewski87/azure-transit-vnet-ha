###############################################################################
# Phase 2 – Panorama Configuration
# Osobny katalog Terraform z providerem panos
#
# Uruchom DOPIERO gdy:
#   1. Phase 1 jest wdrożona (terraform apply w katalogu głównym)
#   2. Panorama VM jest uruchomiona (~10 min po Phase 1)
#   3. Wypełnisz terraform.tfvars w tym katalogu
#
# Użycie:
#   cd phase2-panorama-config/
#   cp terraform.tfvars.example terraform.tfvars
#   # Uzupełnij terraform.tfvars
#   terraform init
#   terraform apply
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

# Provider panos – łączy się do Panoramy przez HTTPS (port 443)
# panorama_hostname musi być ustawiony PRZED wykonaniem terraform apply
provider "panos" {
  hostname = var.panorama_hostname
  username = var.panorama_username
  password = var.panorama_password
}
