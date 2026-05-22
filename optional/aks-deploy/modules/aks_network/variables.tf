###############################################################################
# AKS Network Module – Variables
###############################################################################

variable "location" {
  description = "Azure region (must match the existing transit VNet's location)"
  type        = string
}

variable "aks_resource_group_name" {
  description = "Resource group for spoke3 + AKS resources"
  type        = string
  default     = "rg-app3-aks"
}

variable "spoke3_vnet_address_space" {
  description = "CIDR for the new AKS spoke VNet (must not overlap with existing spokes/transit/mgmt)"
  type        = string
  default     = "10.114.0.0/16"
}

variable "aks_nodes_subnet_cidr" {
  description = "Subnet for AKS node pool"
  type        = string
  default     = "10.114.0.0/24"
}

variable "aks_ilb_subnet_cidr" {
  description = "Subnet for the AKS internal load balancer (ingress-nginx frontend)"
  type        = string
  default     = "10.114.1.0/27"
}

variable "transit_vnet_id" {
  description = "Resource ID of the existing Transit Hub VNet — for bidirectional peering"
  type        = string
}

variable "transit_vnet_name" {
  description = "Name of the existing Transit Hub VNet (for peering on hub side)"
  type        = string
}

variable "transit_resource_group_name" {
  description = "Resource group of the Transit Hub VNet (hub side of peering)"
  type        = string
}

variable "internal_lb_private_ip" {
  description = "Private IP of the existing transit Internal LB frontend (UDR next-hop for AKS outbound)"
  type        = string
  default     = "10.110.0.21"
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default     = {}
}
