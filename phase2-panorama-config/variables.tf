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
  description = "Hostname assigned to Panorama via the XML API in Step 2."
  type        = string
  default     = "panorama-transit-hub"
}

variable "panorama_serial_number" {
  description = <<-EOT
    Panorama serial number from the CSP Portal (my.paloaltonetworks.com → Assets → Panorama).
    Required for BYOL license activation. Format: 007300XXXXXXX (13 digits).
    If left empty, Step 3 (set serial + commit + 'request license fetch')
    is silently skipped. The script will still set up Template Stack, Device
    Group and vm-auth-key, but Panorama will run unlicensed (no log retention,
    no Strata Logging Service, etc.).
  EOT
  type        = string
  default     = ""
}

variable "panorama_device_otp" {
  description = <<-EOT
    One-Time Password for Panorama's device certificate, generated in CSP Portal
    (my.paloaltonetworks.com -> Assets -> Device Certificates -> Generate OTP)
    against Panorama's serial number. 60-minute lifetime, single-use.
    Used for `request device-certificate fetch otp <OTP>` after license activation.
    Empty = skip the fetch (Panorama runs without a device certificate — fine
    for lab; missing some Strata cloud features like Strata Logging Service).
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "panorama_port" {
  description = "Port to connect to Panorama. 44300 = Bastion tunnel, 443 = direct."
  type        = number
  default     = 44300
}

variable "panorama_username" {
  description = "Panorama administrator username"
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
  description = "Panorama Template name"
  type        = string
  default     = "Transit-VNet-Template"
}

variable "template_stack_name" {
  description = "Panorama Template Stack name"
  type        = string
  default     = "Transit-VNet-Stack"
}

variable "device_group_name" {
  description = "Panorama Device Group name"
  type        = string
  default     = "Transit-VNet-DG"
}

#------------------------------------------------------------------------------
# Network CIDRs (must match Phase 1)
# Default values match Phase 1 reference architecture
#------------------------------------------------------------------------------
variable "trust_subnet_cidr" {
  description = "Trust subnet CIDR (FW eth1/2) = cidrsubnet(transit, 8, 0)"
  type        = string
  default     = "10.110.0.0/24"
}

variable "untrust_subnet_cidr" {
  description = "Untrust subnet CIDR (FW eth1/1) = cidrsubnet(transit, 8, 129)"
  type        = string
  default     = "10.110.129.0/24"
}

variable "spoke1_vnet_cidr" {
  description = "Spoke1 (App1) VNet CIDR"
  type        = string
  default     = "10.112.0.0/16"
}

variable "spoke2_vnet_cidr" {
  description = "Spoke2 (App2/DC) VNet CIDR"
  type        = string
  default     = "10.113.0.0/16"
}

#------------------------------------------------------------------------------
# Endpoints
#------------------------------------------------------------------------------
variable "apache_server_ip" {
  description = "Apache server private IP in Spoke1 (DNAT target)"
  type        = string
  default     = "10.112.0.4"
}

variable "external_lb_public_ip" {
  description = "External LB public IP (DNAT source). Get: terraform output external_lb_public_ip"
  type        = string
}
