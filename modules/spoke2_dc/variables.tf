###############################################################################
# Spoke2 DC Module Variables
# Windows Server 2022 Domain Controller + Azure Bastion
###############################################################################

variable "location" {
  description = "Azure region"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group for Spoke2 DC resources"
  type        = string
}

variable "workload_subnet_id" {
  description = "Spoke2 workload subnet ID for DC NIC"
  type        = string
}

variable "bastion_subnet_id" {
  description = "AzureBastionSubnet ID in Spoke2 VNet"
  type        = string
}

variable "dc_private_ip" {
  description = "Static private IP for Domain Controller"
  type        = string
  default     = "10.2.0.4"
}

variable "dc_vm_size" {
  description = "Azure VM size for Windows Server DC"
  type        = string
  default     = "Standard_D2s_v3"
}

variable "admin_username" {
  description = "Administrator username for Windows Server"
  type        = string
  default     = "dcadmin"
}

variable "admin_password" {
  description = "Administrator password for Windows Server (must meet complexity requirements)"
  type        = string
  sensitive   = true
}

variable "domain_name" {
  description = "Active Directory domain name (e.g. panw.labs)"
  type        = string
  default     = "panw.labs"
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
