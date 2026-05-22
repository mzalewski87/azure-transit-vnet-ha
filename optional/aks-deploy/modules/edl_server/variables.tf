###############################################################################
# EDL Server Module – Variables
###############################################################################

variable "location" {
  description = "Azure region (must match the management VNet's location)"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group for the EDL VM + NIC + NSG (same RG as Panorama)"
  type        = string
}

variable "management_vnet_name" {
  description = "Existing Management VNet name (created by root module — networking)"
  type        = string
}

variable "edl_subnet_cidr" {
  description = "CIDR for the new snet-edl subnet inside the Management VNet"
  type        = string
  default     = "10.255.2.0/27"
}

variable "edl_private_ip" {
  description = "Static private IP for the EDL nginx server (must be inside edl_subnet_cidr)"
  type        = string
  default     = "10.255.2.4"
}

variable "fw_mgmt_subnet_cidr" {
  description = "CIDR of the FW management subnet (snet-mgmt in transit VNet) — only source allowed to pull EDLs"
  type        = string
  default     = "10.110.255.0/24"
}

variable "aks_region" {
  description = "AKS cluster region — used to template *.hcp.<region>.azmk8s.io and to select AzureCloud.<region> from Service Tags JSON"
  type        = string
  default     = "germanywestcentral"
}

variable "admin_username" {
  description = "SSH admin username for the EDL VM"
  type        = string
  default     = "edladmin"
}

variable "admin_password" {
  description = "SSH admin password for the EDL VM (sensitive)"
  type        = string
  sensitive   = true
}

variable "vm_size" {
  description = "VM size for the EDL server (modest — single nginx + cron Python)"
  type        = string
  default     = "Standard_B1ms"
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default     = {}
}
