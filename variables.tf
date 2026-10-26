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
  description = <<-EOT
    VM size for Panorama (min 8 vCPU, recommended 16 vCPU / 64 GB).
    Default Standard_D16s_v5. v3 sizes are not offered on newer subscriptions
    (SkuNotAvailable / NotAvailableForSubscription) — run
    scripts/preflight-check.sh to verify the size in your region BEFORE apply.
  EOT
  type        = string
  default     = "Standard_D16s_v5"
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
  description = "VM size for VM-Series FW (8 vCPU; default Standard_D8s_v5 — v3 is not offered on newer subscriptions)"
  type        = string
  default     = "Standard_D8s_v5"
}

variable "app1_vm_size" {
  description = "VM size for the Spoke1 Apache demo server (default Standard_D2s_v5; v3/B-series are not offered on every subscription/region)"
  type        = string
  default     = "Standard_D2s_v5"
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
# VM-Series Auto-Registration PIN (CSP Portal -> Assets -> Device Certificates
# -> Generate Registration PIN)
#
# This is the device-certificate flow for the FIREWALLS.
#
# Why PIN instead of OTP for FWs:
#   - OTPs are generated against a SPECIFIC serial number. VM-Series BYOL
#     serials are assigned by PAN-OS at first boot during license activation
#     — they are NOT known pre-deploy, so per-serial OTPs cannot be
#     pre-generated.
#   - Registration PIN is per-CSP-account, NOT per-serial. The same PIN ID
#     + Value pair works for any FW launched against your account, including
#     both FWs in this HA pair.
#   - The PIN is consumed at FW BOOT (not via post-boot API call). It is
#     written into the init-cfg.txt as vm-series-auto-registration-pin-id
#     and vm-series-auto-registration-pin-value, which the FW reads from
#     IMDS during bootstrap and uses to register itself + fetch its device
#     certificate automatically. No separate post-boot fetch step is
#     possible or needed.
#
# Panorama uses a different mechanism (per-serial OTP) — see
# phase2-panorama-config/variables.tf for panorama_device_otp. Panorama's
# serial IS known pre-deploy because it is supplied via panorama_serial_number.
#
# PIN expires after the period chosen in CSP Portal (typically 30/60/90 days).
# For one-shot deployments (this lab), pick the shortest period that fits
# your deploy window.
#
# Empty = skip the device-cert auto-fetch lines in init-cfg (FW boots without
# a device certificate — fine for lab, missing some Strata cloud features).
#
# Ref: VM-Series Deployment Guide v11.1, pages 178-181 ("License the VM-Series
# Firewall — Retrieve Licenses Automatically at Launch").
#------------------------------------------------------------------------------
variable "fw_registration_pin_id" {
  description = <<-EOT
    VM-Series Auto-Registration PIN ID from CSP Portal (Assets -> Device
    Certificates -> Generate Registration PIN). Shared across ALL FWs in your
    CSP account — one pair (id + value) works for both FW1 and FW2 here.
    Used at FW first boot only; not consumed via API afterwards.
    Empty = skip device-cert auto-fetch.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "fw_registration_pin_value" {
  description = <<-EOT
    Companion PIN Value for fw_registration_pin_id. Both must be non-empty
    for the init-cfg to include the auto-registration lines.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "pan_os_version" {
  description = <<-EOT
    PAN-OS version for the VM-Series FW Marketplace image.
    MUST be <= the Panorama version (Panorama silently refuses newer devices:
    Connected=no, "device_registered no"). 'latest' is NOT safe: the VM-Series
    'latest' image can be a newer train (12.2.x) than the Panorama 'latest'
    (12.1.x). scripts/preflight-check.sh shows the newest Panorama version;
    pin to it (or lower).
  EOT
  type        = string
  default     = "12.1.9"
}

#------------------------------------------------------------------------------
# PAN-OS upgrade (Phase 2c — optional, orchestrated from Panorama)
# Consumed by scripts/upgrade-panos.sh via `terraform output -json
# panos_upgrade`; run automatically at the end of Phase 2b when enabled.
#------------------------------------------------------------------------------
variable "panos_auto_upgrade" {
  description = <<-EOT
    Upgrade PAN-OS automatically at the end of the deployment (end of Phase 2b,
    scripts/register-fw-panorama.sh → scripts/upgrade-panos.sh). Requires
    panos_upgrade_target_version. Default false: FWs stay on pan_os_version.
  EOT
  type        = bool
  default     = false
}

variable "panos_upgrade_target_version" {
  description = <<-EOT
    PAN-OS version to upgrade the firewalls to (e.g. "12.2.4" or "12.2.4-h1").
    The required base-image chain is computed and downloaded automatically
    (skip up to 3 feature releases per install). Panorama is upgraded first
    when it runs an older version (see panos_upgrade_panorama).
    Also used as the default target for a manual `scripts/upgrade-panos.sh`.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = can(regex("^$|^\\d+\\.\\d+\\.\\d+(-h\\d+)?$", var.panos_upgrade_target_version))
    error_message = "panos_upgrade_target_version must look like 12.2.4 or 12.2.4-h1 (or be empty)."
  }
}

variable "panos_upgrade_panorama" {
  description = <<-EOT
    Allow the upgrade to upgrade Panorama first when it is older than
    panos_upgrade_target_version (Panorama must run >= its firewalls).
    false = abort instead, leaving Panorama untouched.
  EOT
  type        = bool
  default     = true
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
