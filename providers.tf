###############################################################################
# Terraform & Provider Configuration
# Azure Transit VNet - VM-Series HA Reference Architecture
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
    panos = {
      source  = "PaloAltoNetworks/panos"
      version = "~> 1.11"
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
  alias = "spoke1"
  features {}
  subscription_id = var.spoke1_subscription_id
}

# Spoke 2 provider (may be a different subscription)
provider "azurerm" {
  alias = "spoke2"
  features {}
  subscription_id = var.spoke2_subscription_id
}

# Panorama provider
# Phase 1: panorama_public_ip is "" → panos provider init succeeds but no resources applied
# Phase 2: set panorama_public_ip in terraform.tfvars after Panorama VM is running
provider "panos" {
  hostname = var.panorama_public_ip
  username = var.admin_username
  password = var.admin_password
}

###############################################################################
# Panorama IP variable (needed here for provider config)
# Set to "" for Phase 1, then fill in after Panorama VM boots (Phase 2)
###############################################################################
variable "panorama_public_ip" {
  description = <<-EOT
    Public IP of Panorama VM for panos Terraform provider.
    Phase 1: leave as "" (panorama_config module not applied)
    Phase 2: set to module.panorama.panorama_public_ip output value
    and run: terraform apply (without -target flags)
  EOT
  type        = string
  default     = ""
}
