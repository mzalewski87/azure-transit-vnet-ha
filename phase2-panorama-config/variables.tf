###############################################################################
# Phase 2 Variables – Panorama Configuration
###############################################################################

#------------------------------------------------------------------------------
# Panorama Connection
#------------------------------------------------------------------------------
variable "panorama_hostname" {
  description = <<-EOT
    Hostname/IP do połączenia z Panoramą (panos provider + curl API calls).
    Gdy używasz az network bastion tunnel: ustaw "127.0.0.1"
    Gdy używasz VPN/jump-host: ustaw prywatne IP Panoramy "10.255.0.4"
  EOT
  type    = string
  default = "127.0.0.1"
}

variable "panorama_target_hostname" {
  description = <<-EOT
    Docelowy hostname Panoramy (ustawiany przez XML API).
    Musi zgadzać się z panorama_hostname w terraform.tfvars Phase 1.
  EOT
  type    = string
  default = "panorama-transit-hub"
}

variable "panorama_serial_number" {
  description = <<-EOT
    Numer seryjny Panoramy z CSP Portal (my.paloaltonetworks.com).
    WYMAGANY do aktywacji licencji BYOL.

    Jak uzyskać:
      1. Zaloguj się na CSP Portal: my.paloaltonetworks.com
      2. Assets → Add Product → wpisz auth-code → wybierz Panorama
      3. CSP przypisze Serial Number (format: 007300XXXXXXX)
      4. Skopiuj go tutaj.

    Jeśli pusty (""), krok aktywacji licencji jest pomijany.
  EOT
  type    = string
  default = ""
}

variable "panorama_port" {
  description = <<-EOT
    Port do połączenia z Panoramą.
    Domyślnie 44300 – odpowiada --port 44300 w az network bastion tunnel.
    Jeśli używasz połączenia direct (VPN/jump-host): ustaw 443.
  EOT
  type    = number
  default = 44300
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
# Panorama Template & Device Group Names
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
#------------------------------------------------------------------------------
variable "trust_subnet_cidr" {
  description = "CIDR subnetu trust (FW eth1/2)"
  type        = string
  default     = "10.0.2.0/24"
}

variable "untrust_subnet_cidr" {
  description = "CIDR subnetu untrust (FW eth1/1)"
  type        = string
  default     = "10.0.1.0/24"
}

variable "spoke1_vnet_cidr" {
  description = "CIDR VNet Spoke1 (trasa do Apache)"
  type        = string
  default     = "10.1.0.0/16"
}

variable "spoke2_vnet_cidr" {
  description = "CIDR VNet Spoke2 (trasa do DC)"
  type        = string
  default     = "10.2.0.0/16"
}

#------------------------------------------------------------------------------
# Endpoints (pobierz z: cd .. && terraform output)
#------------------------------------------------------------------------------
variable "apache_server_ip" {
  description = "IP serwera Apache w Spoke1 (cel DNAT). Pobierz z: terraform output apache_server_private_ip"
  type        = string
  default     = "10.1.0.4"
}

variable "external_lb_public_ip" {
  description = "Publiczny IP External LB (źródło DNAT). Pobierz z: terraform output external_lb_public_ip"
  type        = string
}
