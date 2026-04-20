###############################################################################
# Root Module Variables
# Azure Transit VNet – VM-Series HA Reference Architecture
###############################################################################

#------------------------------------------------------------------------------
# Azure Subscriptions
#------------------------------------------------------------------------------
variable "hub_subscription_id" {
  description = "Hub subscription ID (Management VNet + Transit VNet + Bootstrap SA)"
  type        = string
}

variable "spoke1_subscription_id" {
  description = "App1 (Spoke1) subscription ID – application workloads"
  type        = string
}

variable "spoke2_subscription_id" {
  description = "App2 (Spoke2) subscription ID – Windows DC"
  type        = string
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
}

variable "dc_admin_username" {
  description = "Administrator username for Windows DC VM"
  type        = string
  default     = "dcadmin"
}

variable "dc_admin_password" {
  description = "Administrator password for Windows DC VM"
  type        = string
  sensitive   = true
}

#------------------------------------------------------------------------------
# Panorama Configuration
#------------------------------------------------------------------------------
variable "panorama_private_ip" {
  description = "Static private IP for Panorama in Management VNet snet-management"
  type        = string
  default     = "10.255.0.4"
}

variable "panorama_hostname" {
  description = "Hostname for Panorama (set via init-cfg bootstrap)"
  type        = string
  default     = "panorama-transit-hub"
}

variable "panorama_serial_number" {
  description = <<-EOT
    Panorama serial number from CSP Portal (Assets → Devices).
    Required for automatic license activation via init-cfg.
    Format: 007300XXXXXXX
  EOT
  type        = string
  default     = ""
}

variable "panorama_auth_code" {
  description = "Panorama BYOL license auth code from CSP Portal. Format: XXXX-XXXX-XXXX-XXXX"
  type        = string
  default     = ""
  sensitive   = true
}

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
    Device Registration Auth Key from Panorama (Panorama → Devices → VM Auth Key).
    Generate via SSH: request vm-auth-key generate lifetime 168
    Or via script: ./scripts/generate-vm-auth-key.sh
    Format: 2:XXXXXXXXXXXXXXXX...
    Leave empty to deploy FW without auto-registration (manual or Device Certificate).
  EOT
  type        = string
  default     = ""
  sensitive   = true
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
  description = "VM-Series BYOL license auth code from CSP Portal. Format: XXXX-XXXX-XXXX-XXXX"
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
  type    = string
  default = ""
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
# Bootstrap SA Access
#------------------------------------------------------------------------------
variable "terraform_operator_ips" {
  description = <<-EOT
    Public IP(s) of Terraform operator for Bootstrap SA access.
    Required: SA network_rules.default_action = Deny (Azure Policy).
    Get your IP: curl -s https://api.ipify.org
  EOT
  type        = list(string)
  default     = []
}

#------------------------------------------------------------------------------
# Windows Domain Controller
#------------------------------------------------------------------------------
variable "dc_vm_size" {
  description = "VM size for Windows DC"
  type        = string
  default     = "Standard_B2ms"
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
