###############################################################################
# Spoke2 DC Module Variables
# Windows Server 2022 Domain Controller
# Bastion jest w Management VNet (modules/networking) – nie tutaj
###############################################################################

variable "location" {
  description = "Azure region"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group for DC resources (in App2/Spoke2 subscription)"
  type        = string
}

variable "workload_subnet_id" {
  description = "Workload subnet ID (App2 VNet, snet-workload) where DC VM is placed"
  type        = string
}

variable "admin_username" {
  description = "Administrator username for DC VM"
  type        = string
  default     = "dcadmin"
}

variable "admin_password" {
  description = "Administrator password for DC VM"
  type        = string
  sensitive   = true
}

variable "dc_vm_size" {
  description = "VM size for Domain Controller"
  type        = string
  default     = "Standard_B2ms"
}

variable "domain_name" {
  description = "Active Directory domain name (FQDN)"
  type        = string
  default     = "panw.labs"
}

variable "skip_auto_promote" {
  description = "If true, skip automatic DC promotion (promote manually via optional/dc-promote)"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
