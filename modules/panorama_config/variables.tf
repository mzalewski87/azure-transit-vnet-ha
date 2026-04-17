###############################################################################
# Panorama Config Module Variables
# Configures Panorama via panos Terraform provider
# Phase 2 deploy: requires Panorama VM to be running and accessible
###############################################################################

variable "panorama_hostname" {
  description = "Public IP or FQDN of Panorama management interface"
  type        = string
}

variable "panorama_username" {
  description = "Panorama administrator username"
  type        = string
}

variable "panorama_password" {
  description = "Panorama administrator password"
  type        = string
  sensitive   = true
}

variable "template_name" {
  description = "Panorama Template name (applied to Template Stack)"
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

# Network CIDRs for routing and NAT
variable "trust_subnet_cidr" {
  description = "Trust subnet CIDR (for default gateway calculation)"
  type        = string
  default     = "10.0.2.0/24"
}

variable "untrust_subnet_cidr" {
  description = "Untrust subnet CIDR (for default gateway calculation)"
  type        = string
  default     = "10.0.1.0/24"
}

variable "spoke1_vnet_cidr" {
  description = "Spoke1 VNet CIDR (for virtual router static routes)"
  type        = string
  default     = "10.1.0.0/16"
}

variable "spoke2_vnet_cidr" {
  description = "Spoke2 VNet CIDR (for virtual router static routes)"
  type        = string
  default     = "10.2.0.0/16"
}

variable "apache_server_ip" {
  description = "Apache server private IP in Spoke1 (DNAT destination for inbound HTTP/HTTPS)"
  type        = string
  default     = "10.1.0.4"
}

variable "external_lb_public_ip" {
  description = "External Load Balancer public IP (DNAT source for inbound traffic)"
  type        = string
}
