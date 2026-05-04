###############################################################################
# Root Module Variables
# Azure Transit VNet – VM-Series HA Reference Architecture
###############################################################################

#------------------------------------------------------------------------------
# Azure Subscriptions
#------------------------------------------------------------------------------
variable "hub_subscription_id" {
  description = "Hub subscription ID (Management VNet + Transit VNet)"
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.hub_subscription_id))
    error_message = "hub_subscription_id must be an Azure subscription UUID."
  }
}

variable "spoke1_subscription_id" {
  description = "App1 (Spoke1) subscription ID – application workloads"
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.spoke1_subscription_id))
    error_message = "spoke1_subscription_id must be an Azure subscription UUID."
  }
}

variable "spoke2_subscription_id" {
  description = "App2 (Spoke2) subscription ID – Windows DC"
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.spoke2_subscription_id))
    error_message = "spoke2_subscription_id must be an Azure subscription UUID."
  }
}

#------------------------------------------------------------------------------
# Location & Resource Groups
#------------------------------------------------------------------------------
variable "location" {
  description = "Azure region for all resources"
  type        = string
  default     = "germanywestcentral"
}

variable "hub_resource_group_name" {
  description = "Resource group for hub resources (Management VNet + Transit VNet)"
  type        = string
  default     = "rg-transit-hub"
}

variable "app1_resource_group_name" {
  description = "Resource group for App1 VNet (spoke1 subscription)"
  type        = string
  default     = "rg-app1"
}

variable "app2_resource_group_name" {
  description = "Resource group for App2 VNet + DC (spoke2 subscription)"
  type        = string
  default     = "rg-app2-dc"
}

#------------------------------------------------------------------------------
# VNet Address Spaces (matching PANW reference architecture)
#------------------------------------------------------------------------------
variable "management_vnet_address_space" {
  description = "CIDR for Management VNet (Panorama + Bastion)"
  type        = string
  default     = "10.255.0.0/16"
}

variable "transit_vnet_address_space" {
  description = "CIDR for Transit Hub VNet (VM-Series HA pair)"
  type        = string
  default     = "10.110.0.0/16"
}

variable "app1_vnet_address_space" {
  description = "CIDR for App1 VNet (application workloads)"
  type        = string
  default     = "10.112.0.0/16"
}

variable "app2_vnet_address_space" {
  description = "CIDR for App2 VNet (Windows DC)"
  type        = string
  default     = "10.113.0.0/16"
}

#------------------------------------------------------------------------------
# Authentication (shared across all VMs)
#------------------------------------------------------------------------------
variable "admin_username" {
  description = "Administrator username for Panorama and VM-Series FW"
  type        = string
  default     = "panadmin"
}

variable "admin_password" {
  description = "Administrator password for Panorama and VM-Series FW (min 12 chars, upper/lower/digit/special)"
  type        = string
  sensitive   = true

  validation {
    condition = (
      length(var.admin_password) >= 12 &&
      can(regex("[A-Z]", var.admin_password)) &&
      can(regex("[a-z]", var.admin_password)) &&
      can(regex("[0-9]", var.admin_password)) &&
      can(regex("[^A-Za-z0-9]", var.admin_password))
    )
    error_message = "admin_password must be at least 12 characters and contain uppercase, lowercase, digit and special character."
  }
}

variable "dc_admin_username" {
  description = "Administrator username for Windows DC VM"
  type        = string
  default     = "dcadmin"
}

variable "dc_admin_password" {
  description = "Administrator password for Windows DC VM (min 12 chars, upper/lower/digit/special)"
  type        = string
  sensitive   = true

  validation {
    condition = (
      length(var.dc_admin_password) >= 12 &&
      can(regex("[A-Z]", var.dc_admin_password)) &&
      can(regex("[a-z]", var.dc_admin_password)) &&
      can(regex("[0-9]", var.dc_admin_password)) &&
      can(regex("[^A-Za-z0-9]", var.dc_admin_password))
    )
    error_message = "dc_admin_password must be at least 12 characters and contain uppercase, lowercase, digit and special character."
  }
}

#------------------------------------------------------------------------------
# Panorama Configuration
#------------------------------------------------------------------------------
variable "panorama_private_ip" {
  description = "Static private IP for Panorama in Management VNet snet-management"
  type        = string
  default     = "10.255.0.4"
}

# panorama_serial_number and panorama_auth_code REMOVED from Phase 1
# License activation happens via XML API in Phase 2 (phase2-panorama-config/)
# Provide auth_code as panorama_auth_code in phase2-panorama-config/terraform.tfvars

variable "panorama_vm_size" {
  description = "VM size for Panorama (min Standard_D8s_v3, recommended Standard_D16s_v3)"
  type        = string
  default     = "Standard_D16s_v3"
}

variable "panorama_log_disk_size_gb" {
  description = "Log disk size for Panorama in GB"
  type        = number
  default     = 2048
}

#------------------------------------------------------------------------------
# Panorama Templates (used in FW init-cfg and phase2-panorama-config)
#------------------------------------------------------------------------------
variable "panorama_template_stack" {
  description = "Panorama Template Stack name (must match phase2-panorama-config)"
  type        = string
  default     = "Transit-VNet-Stack"
}

variable "panorama_device_group" {
  description = "Panorama Device Group name (must match phase2-panorama-config)"
  type        = string
  default     = "Transit-VNet-DG"
}

variable "panorama_vm_auth_key" {
  description = <<-EOT
    Device Registration Auth Key from Panorama (Panorama -> Devices -> VM Auth Key).
    Generate via SSH: request vm-auth-key generate lifetime 168
    Or via script: ./scripts/generate-vm-auth-key.sh
    Format: 2:XXXXXXXXXXXXXXXX...
    Leave empty to deploy FW without auto-registration (manual or Device Certificate).
  EOT
  type        = string
  default     = ""
  sensitive   = true

  validation {
    condition     = var.panorama_vm_auth_key == "" || can(regex("^2:[A-Za-z0-9+/=_-]{20,}$", var.panorama_vm_auth_key))
    error_message = "panorama_vm_auth_key must be empty or match Panorama auth key format '2:XXXXXX...' (min 20 chars after the prefix)."
  }
}

#------------------------------------------------------------------------------
# VM-Series Firewall Configuration
#------------------------------------------------------------------------------
variable "fw_vm_size" {
  description = "VM size for VM-Series FW (8 vCPU = Standard_D8s_v3)"
  type        = string
  default     = "Standard_D8s_v3"
}

variable "fw_auth_code" {
  description = "VM-Series BYOL license auth code from CSP Portal. Format: XXXXXXXX (8 alphanumeric chars)"
  type        = string
  default     = ""
  sensitive   = true

  validation {
    condition     = var.fw_auth_code == "" || can(regex("^[A-Z0-9]{8}$", var.fw_auth_code))
    error_message = "fw_auth_code must be empty or 8 uppercase alphanumeric characters (CSP Portal format, e.g. D5541146)."
  }
}

#------------------------------------------------------------------------------
# Device Certificate OTPs (CSP Portal -> Assets -> Device Certificates)
#
# Each device (Panorama, FW1, FW2) needs its own OTP. Generate per-serial
# at my.paloaltonetworks.com. OTP is valid for 60 minutes and is single-use.
# Leave empty to skip the device-certificate fetch step (device will run
# without one — fine for lab, missing some Strata cloud features).
#------------------------------------------------------------------------------
variable "fw1_device_otp" {
  description = <<-EOT
    One-Time Password for FW1 device certificate, generated in CSP Portal
    (my.paloaltonetworks.com -> Assets -> Device Certificates -> Generate OTP)
    against FW1's serial number. 60-minute lifetime, single-use.
    Empty = skip the fetch (FW operates without a device certificate).
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "fw2_device_otp" {
  description = <<-EOT
    One-Time Password for FW2 device certificate. Same rules as fw1_device_otp.
    Each FW needs its OWN OTP generated against its OWN serial number — they
    are NOT interchangeable.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "pan_os_version" {
  description = "PAN-OS version for VM-Series FW Marketplace image"
  type        = string
  default     = "latest"
}

#------------------------------------------------------------------------------
# Load Balancer
#------------------------------------------------------------------------------
variable "internal_lb_private_ip" {
  description = <<-EOT
    Static private IP for Internal LB frontend (must be in snet-private = cidrsubnet(transit,8,0)).
    Leave empty (default) to auto-compute: host #21 in trust subnet.
    Example: transit=10.110.0.0/16 → snet-private=10.110.0.0/24 → auto IP=10.110.0.21
    Example: transit=10.0.0.0/16   → snet-private=10.0.0.0/24   → auto IP=10.0.0.21
  EOT
  type        = string
  default     = ""
}

#------------------------------------------------------------------------------
# Front Door
#------------------------------------------------------------------------------
variable "frontdoor_sku" {
  description = "Azure Front Door SKU (Premium_AzureFrontDoor recommended for WAF)"
  type        = string
  default     = "Premium_AzureFrontDoor"
}

#------------------------------------------------------------------------------
# Windows Domain Controller
#------------------------------------------------------------------------------
variable "dc_vm_size" {
  description = "VM size for Windows DC"
  type        = string
  default     = "Standard_B2s_v2"
}

variable "dc_domain_name" {
  description = "Active Directory domain name (FQDN)"
  type        = string
  default     = "panw.labs"
}

variable "dc_skip_auto_promote" {
  description = "Skip automatic DC promotion (promote manually via optional/dc-promote)"
  type        = bool
  default     = false
}

#------------------------------------------------------------------------------
# Tags
#------------------------------------------------------------------------------
variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default = {
    Project     = "azure-transit-vnet-ha"
    ManagedBy   = "Terraform"
    Environment = "Demo"
  }
}
