###############################################################################
# Phase 2 Variables – Panorama Configuration
###############################################################################

#------------------------------------------------------------------------------
# Panorama Connection
#------------------------------------------------------------------------------
variable "panorama_hostname" {
  description = "Public IP lub FQDN Panoramy. Pobierz z: cd .. && terraform output panorama_public_ip"
  type        = string
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
