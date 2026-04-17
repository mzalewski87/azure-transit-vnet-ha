###############################################################################
# Terraform & Provider Configuration
# Azure Transit VNet - VM-Series HA Reference Architecture
#
# Phase 1 (ten katalog): azurerm + random ONLY
# Phase 2 (katalog phase2-panorama-config/): panos provider
#
# Separacja providerów jest wymagana, ponieważ panos provider zawsze próbuje
# połączyć się z Panoramą podczas terraform plan, nawet jeśli brak zasobów.
# Rozdzielenie na dwa katalogi eliminuje ten problem.
###############################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

# Hub/Transit provider (default)
provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
    virtual_machine {
      delete_os_disk_on_deletion     = true
      graceful_shutdown              = false
      skip_shutdown_and_force_delete = false
    }
  }
  subscription_id = var.hub_subscription_id
}

# Spoke 1 provider (may be a different subscription)
provider "azurerm" {
  alias           = "spoke1"
  features {}
  subscription_id = var.spoke1_subscription_id
}

# Spoke 2 provider (may be a different subscription)
provider "azurerm" {
  alias           = "spoke2"
  features {}
  subscription_id = var.spoke2_subscription_id
}
