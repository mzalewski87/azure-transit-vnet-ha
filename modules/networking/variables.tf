###############################################################################
# Networking Module Variables
###############################################################################

variable "location" {
  description = "Azure region"
  type        = string
}

variable "hub_resource_group_name" {
  description = "Resource group for hub/transit resources (Management VNet + Transit VNet)"
  type        = string
}

variable "app1_resource_group_name" {
  description = "Resource group for App1 VNet (spoke1 subscription)"
  type        = string
}

variable "app2_resource_group_name" {
  description = "Resource group for App2 VNet (spoke2 subscription)"
  type        = string
}

variable "management_vnet_address_space" {
  description = "CIDR for Management VNet (Panorama + Bastion). Default: 10.255.0.0/16"
  type        = string
  default     = "10.255.0.0/16"
}

variable "transit_vnet_address_space" {
  description = "CIDR for Transit Hub VNet (VM-Series HA pair). Default: 10.110.0.0/16"
  type        = string
  default     = "10.110.0.0/16"
}

variable "app1_vnet_address_space" {
  description = "CIDR for App1 VNet (application workloads). Default: 10.112.0.0/16"
  type        = string
  default     = "10.112.0.0/16"
}

variable "app2_vnet_address_space" {
  description = "CIDR for App2 VNet (Windows DC / additional workloads). Default: 10.113.0.0/16"
  type        = string
  default     = "10.113.0.0/16"
}

variable "hub_subscription_id" {
  description = "Hub subscription ID (used for cross-subscription peering remote VNet IDs)"
  type        = string
}

variable "spoke1_subscription_id" {
  description = "Spoke1/App1 subscription ID"
  type        = string
}

variable "spoke2_subscription_id" {
  description = "Spoke2/App2 subscription ID"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
