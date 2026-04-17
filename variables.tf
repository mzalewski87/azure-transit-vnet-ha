###############################################################################
# Root Variables
# Azure Transit VNet - VM-Series HA Reference Architecture
###############################################################################

#------------------------------------------------------------------------------
# Subscription IDs
#------------------------------------------------------------------------------
variable "hub_subscription_id" {
  description = "Azure Subscription ID for the Hub/Transit VNet resources"
  type        = string
}

variable "spoke1_subscription_id" {
  description = "Azure Subscription ID for Spoke 1 (can be same as hub for demo)"
  type        = string
}

variable "spoke2_subscription_id" {
  description = "Azure Subscription ID for Spoke 2 (can be same as hub for demo)"
  type        = string
}

#------------------------------------------------------------------------------
# General Settings
#------------------------------------------------------------------------------
variable "location" {
  description = "Azure region for all resources"
  type        = string
  default     = "West Europe"
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default = {
    Environment = "Demo"
    Project     = "PAN-Transit-VNet"
    Owner       = "Network-Team"
    ManagedBy   = "Terraform"
  }
}

#------------------------------------------------------------------------------
# Resource Group Names
#------------------------------------------------------------------------------
variable "hub_resource_group_name" {
  description = "Name of the Hub/Transit resource group"
  type        = string
  default     = "rg-transit-hub"
}

variable "spoke1_resource_group_name" {
  description = "Name of the Spoke 1 resource group"
  type        = string
  default     = "rg-spoke1-app"
}

variable "spoke2_resource_group_name" {
  description = "Name of the Spoke 2 resource group"
  type        = string
  default     = "rg-spoke2-app"
}

#------------------------------------------------------------------------------
# Network Address Spaces
#------------------------------------------------------------------------------
variable "transit_vnet_address_space" {
  description = "Address space for the Transit (Hub) VNet. Must be /16 or larger."
  type        = string
  default     = "10.0.0.0/16"
}

variable "spoke1_vnet_address_space" {
  description = "Address space for Spoke 1 VNet"
  type        = string
  default     = "10.1.0.0/16"
}

variable "spoke2_vnet_address_space" {
  description = "Address space for Spoke 2 VNet"
  type        = string
  default     = "10.2.0.0/16"
}

#------------------------------------------------------------------------------
# VM-Series Firewall Settings
#------------------------------------------------------------------------------
variable "fw_vm_size" {
  description = "Azure VM size for VM-Series firewalls (must be 8+ vCPU)"
  type        = string
  default     = "Standard_D8s_v3"
}

variable "pan_os_version" {
  description = "PAN-OS image version for VM-Series (BYOL)"
  type        = string
  default     = "11.1.4"
}

variable "admin_username" {
  description = "Administrator username for VM-Series firewalls"
  type        = string
  default     = "panadmin"
}

variable "admin_password" {
  description = "Administrator password for VM-Series firewalls (min 12 chars, mixed case, numbers, special)"
  type        = string
  sensitive   = true
}

#------------------------------------------------------------------------------
# Internal LB IP (next-hop for UDR)
#------------------------------------------------------------------------------
variable "internal_lb_private_ip" {
  description = "Static private IP for the Internal Load Balancer frontend (Trust subnet)"
  type        = string
  default     = "10.0.2.100"
}

#------------------------------------------------------------------------------
# Azure Front Door
#------------------------------------------------------------------------------
variable "frontdoor_sku" {
  description = "Azure Front Door SKU: Standard_AzureFrontDoor or Premium_AzureFrontDoor"
  type        = string
  default     = "Premium_AzureFrontDoor"

  validation {
    condition     = contains(["Standard_AzureFrontDoor", "Premium_AzureFrontDoor"], var.frontdoor_sku)
    error_message = "frontdoor_sku must be either 'Standard_AzureFrontDoor' or 'Premium_AzureFrontDoor'."
  }
}

#------------------------------------------------------------------------------
# PAN-OS License Auth Codes (sensitive – never commit values to source control)
# Provide via terraform.tfvars (local, gitignored) or TF_VAR_* env variables
#------------------------------------------------------------------------------
variable "fw_auth_code" {
  description = <<-EOT
    VM-Series BYOL auth code from Palo Alto Customer Support Portal.
    Portal: https://support.paloaltonetworks.com → Assets → Auth Codes
    Used in bootstrap to activate VM-Series licenses automatically.
  EOT
  type        = string
  sensitive   = true
}

variable "panorama_auth_code" {
  description = <<-EOT
    Panorama BYOL auth code from Palo Alto Customer Support Portal.
    Portal: https://support.paloaltonetworks.com → Assets → Auth Codes
  EOT
  type        = string
  sensitive   = true
}

variable "panorama_vm_auth_key" {
  description = <<-EOT
    VM Auth Key generated in Panorama (Panorama → Devices → VM Auth Key → Generate).
    Used by VM-Series bootstrap to auto-register with Panorama.
    IMPORTANT: Generate AFTER Panorama VM is running (deploy Phase 2).
    Set to empty string "" for Phase 1 deploy, then re-apply after generating.
  EOT
  type        = string
  sensitive   = true
  default     = ""
}

#------------------------------------------------------------------------------
# Panorama Configuration
#------------------------------------------------------------------------------
variable "panorama_template_stack" {
  description = "Panorama Template Stack name (created by panorama_config module)"
  type        = string
  default     = "Transit-VNet-Stack"
}

variable "panorama_device_group" {
  description = "Panorama Device Group name (created by panorama_config module)"
  type        = string
  default     = "Transit-VNet-DG"
}

variable "panorama_vm_size" {
  description = "Azure VM size for Panorama"
  type        = string
  default     = "Standard_D4s_v3"
}

variable "panorama_log_disk_size_gb" {
  description = "Data disk size in GB for Panorama log storage"
  type        = number
  default     = 2048
}

#------------------------------------------------------------------------------
# Windows Domain Controller (Spoke2)
#------------------------------------------------------------------------------
variable "dc_admin_username" {
  description = "Administrator username for Windows Server Domain Controller"
  type        = string
  default     = "dcadmin"
}

variable "dc_admin_password" {
  description = <<-EOT
    Administrator password for Windows Server DC.
    Must meet Windows complexity requirements:
    min 12 chars, uppercase, lowercase, digit, special character.
  EOT
  type        = string
  sensitive   = true
}

variable "dc_domain_name" {
  description = "Active Directory domain name for Domain Controller"
  type        = string
  default     = "panw.labs"
}

variable "dc_vm_size" {
  description = "Azure VM size for Windows Domain Controller"
  type        = string
  default     = "Standard_D2s_v3"
}
