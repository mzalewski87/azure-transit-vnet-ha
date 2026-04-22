###############################################################################
# Phase 2 Variables – Panorama Configuration
###############################################################################

#------------------------------------------------------------------------------
# Panorama Connection
#------------------------------------------------------------------------------
variable "panorama_hostname" {
  description = "Hostname/IP to connect to Panorama. Default 127.0.0.1 (Bastion tunnel)."
  type        = string
  default     = "127.0.0.1"
}

variable "panorama_target_hostname" {
  description = "Docelowy hostname Panoramy (ustawiany przez XML API)."
  type        = string
  default     = "panorama-transit-hub"
}

variable "panorama_serial_number" {
  description = <<-EOT
    Numer seryjny Panoramy z CSP Portal (my.paloaltonetworks.com).
    Required for BYOL license activation. Format: 007300XXXXXXX.
    If empty — license activation step is skipped.
  EOT
  type        = string
  default     = ""
}

variable "panorama_port" {
  description = "Port to connect to Panorama. 44300 = Bastion tunnel, 443 = direct."
  type        = number
  default     = 44300
}

variable "panorama_username" {
  description = "Nazwa administratora Panoramy"
  type        = string
  default     = "panadmin"
}

variable "panorama_password" {
  description = "Panorama admin password (same as admin_password in Phase 1)"
  type        = string
  sensitive   = true
}

#------------------------------------------------------------------------------
# vm-auth-key
#------------------------------------------------------------------------------
variable "vm_auth_key_lifetime" {
  description = <<-EOT
    vm-auth-key lifetime in minutes. PAN-OS maximum = 8760 (365 days).
    Default 1440 = 24h. Key generated automatically in Step 4.
  EOT
  type        = number
  default     = 1440
}

#------------------------------------------------------------------------------
# Panorama Template & Device Group
#------------------------------------------------------------------------------
variable "template_name" {
  description = "Nazwa Panorama Template"
  type        = string
  default     = "Transit-VNet-Template"
}

variable "template_stack_name" {
  description = "Nazwa Panorama Template Stack"
  type        = string
  default     = "Transit-VNet-Stack"
}

variable "device_group_name" {
  description = "Nazwa Panorama Device Group"
  type        = string
  default     = "Transit-VNet-DG"
}

#------------------------------------------------------------------------------
# Network CIDRs (must match Phase 1)
# Default values match Phase 1 reference architecture
#------------------------------------------------------------------------------
variable "trust_subnet_cidr" {
  description = "CIDR subnetu trust (FW eth1/2) = cidrsubnet(transit, 8, 0)"
  type        = string
  default     = "10.110.0.0/24"
}

variable "untrust_subnet_cidr" {
  description = "CIDR subnetu untrust (FW eth1/1) = cidrsubnet(transit, 8, 129)"
  type        = string
  default     = "10.110.129.0/24"
}

variable "spoke1_vnet_cidr" {
  description = "CIDR VNet Spoke1 (App1)"
  type        = string
  default     = "10.112.0.0/16"
}

variable "spoke2_vnet_cidr" {
  description = "CIDR VNet Spoke2 (App2/DC)"
  type        = string
  default     = "10.113.0.0/16"
}

#------------------------------------------------------------------------------
# Endpoints
#------------------------------------------------------------------------------
variable "apache_server_ip" {
  description = "IP serwera Apache w Spoke1 (cel DNAT)"
  type        = string
  default     = "10.112.0.4"
}

variable "external_lb_public_ip" {
  description = "External LB public IP (DNAT source). Get: terraform output external_lb_public_ip"
  type        = string
}
