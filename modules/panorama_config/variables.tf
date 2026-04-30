###############################################################################
# Panorama Config Module Variables
# Configures Panorama via panos Terraform provider
###############################################################################

variable "panorama_hostname" {
  description = "Hostname/IP of Panorama management interface"
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

variable "trust_subnet_cidr" {
  description = "Trust subnet CIDR (FW eth1/2)"
  type        = string
  default     = "10.110.0.0/24"
}

variable "untrust_subnet_cidr" {
  description = "Untrust subnet CIDR (FW eth1/1)"
  type        = string
  default     = "10.110.129.0/24"
}

variable "spoke1_vnet_cidr" {
  description = "Spoke1 VNet CIDR (App1)"
  type        = string
  default     = "10.112.0.0/16"
}

variable "spoke2_vnet_cidr" {
  description = "Spoke2 VNet CIDR (App2/DC)"
  type        = string
  default     = "10.113.0.0/16"
}

variable "apache_server_ip" {
  description = "Apache server private IP in Spoke1 (DNAT destination)"
  type        = string
  default     = "10.112.0.4"
}

variable "external_lb_public_ip" {
  description = "External Load Balancer public IP (DNAT source)"
  type        = string
}

variable "mgmt_subnet_netmask" {
  description = "Netmask for the FW management subnet (HA1 peer-ip variable type ip-netmask)"
  type        = string
  default     = "255.255.255.0"
}
