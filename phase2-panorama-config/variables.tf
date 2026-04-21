###############################################################################
# Phase 2 Variables – Panorama Configuration
###############################################################################

#------------------------------------------------------------------------------
# Panorama Connection
#------------------------------------------------------------------------------
variable "panorama_hostname" {
  description = "Hostname/IP do połączenia z Panoramą. Domyślnie 127.0.0.1 (Bastion tunnel)."
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
    Wymagany do aktywacji licencji BYOL. Format: 007300XXXXXXX.
    Jeśli pusty – krok aktywacji licencji jest pomijany.
  EOT
  type        = string
  default     = ""
}

variable "panorama_port" {
  description = "Port do połączenia z Panoramą. 44300 = Bastion tunnel, 443 = direct."
  type        = number
  default     = 44300
}

variable "panorama_username" {
  description = "Nazwa administratora Panoramy"
  type        = string
  default     = "panadmin"
}

variable "panorama_password" {
  description = "Hasło administratora Panoramy (to samo co admin_password w Phase 1)"
  type        = string
  sensitive   = true
}

#------------------------------------------------------------------------------
# vm-auth-key
#------------------------------------------------------------------------------
variable "vm_auth_key_lifetime" {
  description = <<-EOT
    Czas życia vm-auth-key w minutach. Maksimum PAN-OS = 8760 (365 dni).
    Domyślnie 1440 = 24h. Klucz generowany automatycznie w Step 4.
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
# Network CIDRs (muszą zgadzać się z Phase 1)
# Domyślne wartości odpowiadają architekturze referencyjnej z Phase 1
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
  description = "Publiczny IP External LB (źródło DNAT). Pobierz: terraform output external_lb_public_ip"
  type        = string
}
