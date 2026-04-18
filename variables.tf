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
  description = "Name of the Spoke 2 resource group (contains DC + Spoke2 Bastion)"
  type        = string
  default     = "rg-spoke2-dc"
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
  description = <<-EOT
    PAN-OS image version for VM-Series BYOL SKU.
    Domyślnie "latest" – zawsze najnowsza niewyofana wersja z Marketplace.
    W produkcji przypnij do konkretnej wersji po testach (np. "11.2.3").
    Dostępne wersje:
      az vm image list --publisher paloaltonetworks --offer vmseries-flex \
        --sku byol --all --query "[].version" -o tsv
  EOT
  type        = string
  default     = "latest"
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
  IMPORTANT: Generate AFTER Phase 1a (Panorama running) AND Phase 2 (Panorama config).
  Leave empty "" for Phase 1a deploy. Uzupelnij przed Phase 1b (FW deploy).
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

variable "panorama_serial_number" {
  description = <<-EOT
    Numer seryjny Panoramy z Palo Alto CSP Portal (Assets → Devices).
    Wymagany do automatycznej aktywacji licencji przy starcie VM.
    Format: np. "007300014999" lub "007900000111".
    Zostaw "" jeśli nie znasz – licencja będzie wymagać ręcznej aktywacji.
  EOT
  type    = string
  default = ""
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

#------------------------------------------------------------------------------
# DC Auto-Promote Control
# Domyślnie true – DC promotion jest opcjonalna i wykonywana osobno.
# Patrz: optional/dc-promote/ dla instrukcji promocji DC.
#------------------------------------------------------------------------------
variable "dc_skip_auto_promote" {
  description = <<-EOT
    Pomiń automatyczną promocję DC przez Custom Script Extension w module.spoke2_dc.
    Domyślnie TRUE – promocja DC jest OPCJONALNA i odbywa się w osobnym module.
    Patrz: optional/dc-promote/ – uruchom po Phase 1b jeśli potrzebujesz AD DS.

    Ustaw FALSE tylko jeśli chcesz automatycznej promocji DC razem z Phase 1a
    (ostrzeżenie: znacznie wydłuża czas deploy – 30-45 min dodatkowe).
  EOT
  type    = bool
  default = true
}

#------------------------------------------------------------------------------
# Azure Policy Compliance
#------------------------------------------------------------------------------
variable "terraform_operator_ips" {
  description = <<-EOT
    List of public IP addresses of the machine(s) running terraform apply.
    Required because storage account network_rules has default_action=Deny
    (enforced by Azure Policy: Storage accounts should restrict network access).

    Get your current public IP:
      curl -s https://api.ipify.org

    Example in terraform.tfvars:
      terraform_operator_ips = ["1.2.3.4"]

    Leave empty [] only when running Terraform from within the Azure VNet
    (self-hosted runner, Azure DevOps agent, Cloud Shell).
  EOT
  type        = list(string)
  default     = []
}
