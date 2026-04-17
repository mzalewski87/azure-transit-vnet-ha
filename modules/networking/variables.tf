###############################################################################
# Networking Module Variables
###############################################################################

variable "location" {
  description = "Azure region"
  type        = string
}

variable "hub_resource_group_name" {
  description = "Hub/Transit resource group name"
  type        = string
}

variable "spoke1_resource_group_name" {
  description = "Spoke 1 resource group name"
  type        = string
}

variable "spoke2_resource_group_name" {
  description = "Spoke 2 resource group name"
  type        = string
}

variable "transit_vnet_address_space" {
  description = "Transit VNet CIDR block (/16 recommended)"
  type        = string
  default     = "10.0.0.0/16"
}

variable "spoke1_vnet_address_space" {
  description = "Spoke 1 VNet CIDR block"
  type        = string
  default     = "10.1.0.0/16"
}

variable "spoke2_vnet_address_space" {
  description = "Spoke 2 VNet CIDR block"
  type        = string
  default     = "10.2.0.0/16"
}

variable "hub_subscription_id" {
  description = "Hub subscription ID (used in remote VNet peering resource IDs)"
  type        = string
}

variable "spoke1_subscription_id" {
  description = "Spoke 1 subscription ID"
  type        = string
}

variable "spoke2_subscription_id" {
  description = "Spoke 2 subscription ID"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
