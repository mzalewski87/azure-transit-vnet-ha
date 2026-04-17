###############################################################################
# Firewall Module Variables
###############################################################################

variable "location" {
  description = "Azure region"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group for firewall resources"
  type        = string
}

#------------------------------------------------------------------------------
# VM-Series Image & Size
#------------------------------------------------------------------------------
variable "vm_size" {
  description = "Azure VM size for VM-Series (Standard_D8s_v3 = 8 vCPU / 32 GB)"
  type        = string
  default     = "Standard_D8s_v3"
}

variable "pan_os_version" {
  description = "PAN-OS image version (BYOL SKU)"
  type        = string
  default     = "11.1.4"
}

variable "admin_username" {
  description = "Administrator username"
  type        = string
}

variable "admin_password" {
  description = "Administrator password"
  type        = string
  sensitive   = true
}

#------------------------------------------------------------------------------
# Subnet IDs
#------------------------------------------------------------------------------
variable "mgmt_subnet_id" {
  description = "Management subnet ID (eth0/NIC0)"
  type        = string
}

variable "untrust_subnet_id" {
  description = "Untrust subnet ID (eth1/NIC1)"
  type        = string
}

variable "trust_subnet_id" {
  description = "Trust subnet ID (eth2/NIC2)"
  type        = string
}

variable "ha_subnet_id" {
  description = "HA2 subnet ID (eth3/NIC3)"
  type        = string
}

#------------------------------------------------------------------------------
# Public IP IDs for management interfaces
#------------------------------------------------------------------------------
variable "fw1_mgmt_public_ip_id" {
  description = "Public IP resource ID for FW1 management"
  type        = string
}

variable "fw2_mgmt_public_ip_id" {
  description = "Public IP resource ID for FW2 management"
  type        = string
}

#------------------------------------------------------------------------------
# Load Balancer Backend Pool IDs
#------------------------------------------------------------------------------
variable "external_lb_backend_pool_id" {
  description = "External (Public) LB backend address pool ID"
  type        = string
}

variable "internal_lb_backend_pool_id" {
  description = "Internal LB backend address pool ID"
  type        = string
}

#------------------------------------------------------------------------------
# Static IP configuration
# These IPs must fall within their respective subnet ranges
#------------------------------------------------------------------------------
variable "fw1_mgmt_ip" {
  description = "Static private IP for FW1 management interface (snet-mgmt)"
  type        = string
  default     = "10.0.0.4"
}

variable "fw2_mgmt_ip" {
  description = "Static private IP for FW2 management interface (snet-mgmt)"
  type        = string
  default     = "10.0.0.5"
}

variable "fw1_untrust_ip" {
  description = "Static private IP for FW1 untrust interface (snet-untrust)"
  type        = string
  default     = "10.0.1.4"
}

variable "fw2_untrust_ip" {
  description = "Static private IP for FW2 untrust interface (snet-untrust)"
  type        = string
  default     = "10.0.1.5"
}

variable "fw1_trust_ip" {
  description = "Static private IP for FW1 trust interface (snet-trust)"
  type        = string
  default     = "10.0.2.4"
}

variable "fw2_trust_ip" {
  description = "Static private IP for FW2 trust interface (snet-trust)"
  type        = string
  default     = "10.0.2.5"
}

variable "fw1_ha_ip" {
  description = "Static private IP for FW1 HA2 interface (snet-ha)"
  type        = string
  default     = "10.0.3.4"
}

variable "fw2_ha_ip" {
  description = "Static private IP for FW2 HA2 interface (snet-ha)"
  type        = string
  default     = "10.0.3.5"
}

#------------------------------------------------------------------------------
# Bootstrap (Azure Storage Account via Managed Identity)
#------------------------------------------------------------------------------
variable "bootstrap_custom_data_fw1" {
  description = "base64-encoded custom_data for FW1 pointing to bootstrap storage container"
  type        = string
  sensitive   = true
}

variable "bootstrap_custom_data_fw2" {
  description = "base64-encoded custom_data for FW2 pointing to bootstrap storage container"
  type        = string
  sensitive   = true
}

variable "fw_managed_identity_id" {
  description = "User Assigned Managed Identity resource ID for bootstrap storage access"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
