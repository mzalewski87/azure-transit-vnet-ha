###############################################################################
# Routing Module Variables
###############################################################################

variable "location" {
  description = "Azure region"
  type        = string
}

variable "spoke1_resource_group_name" {
  description = "Resource group name for Spoke 1"
  type        = string
}

variable "spoke2_resource_group_name" {
  description = "Resource group name for Spoke 2"
  type        = string
}

variable "spoke1_workload_subnet_id" {
  description = "Spoke 1 workload subnet ID to associate route table with"
  type        = string
}

variable "spoke2_workload_subnet_id" {
  description = "Spoke 2 workload subnet ID to associate route table with"
  type        = string
}

variable "internal_lb_private_ip" {
  description = "Internal Load Balancer private IP - next-hop for all spoke traffic"
  type        = string
}

variable "spoke1_vnet_address_space" {
  description = "Spoke 1 VNet address space (used for east-west routing between spokes)"
  type        = string
}

variable "spoke2_vnet_address_space" {
  description = "Spoke 2 VNet address space (used for east-west routing between spokes)"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
