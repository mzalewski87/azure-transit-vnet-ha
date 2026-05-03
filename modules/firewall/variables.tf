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
  description = <<-EOT
    PAN-OS image version for VM-Series BYOL SKU.
    Use "latest" to always deploy the most recent non-deprecated version.
    In production, pin to a specific version (e.g. "11.2.3") after testing.
    Check available versions:
      az vm image list --publisher paloaltonetworks --offer vmseries-flex \
        --sku byol --all --query "[].version" -o tsv
  EOT
  type        = string
  default     = "latest"
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
# Subnet CIDRs (used to auto-compute static IPs via cidrhost())
# FW1 gets host .4, FW2 gets host .5 in each subnet
#------------------------------------------------------------------------------
variable "mgmt_subnet_cidr" {
  description = "CIDR of FW management subnet (snet-mgmt) – used to compute FW1/FW2 mgmt IPs"
  type        = string
}

variable "untrust_subnet_cidr" {
  description = "CIDR of FW untrust subnet (snet-public) – used to compute FW1/FW2 untrust IPs"
  type        = string
}

variable "trust_subnet_cidr" {
  description = "CIDR of FW trust subnet (snet-private) – used to compute FW1/FW2 trust IPs"
  type        = string
}

#------------------------------------------------------------------------------
# Bootstrap (init-cfg as base64 custom_data, read by PAN-OS via Azure IMDS)
#------------------------------------------------------------------------------
variable "bootstrap_custom_data_fw1" {
  description = "base64-encoded init-cfg.txt for FW1 (PAN-OS reads via Azure IMDS userData)"
  type        = string
  sensitive   = true
}

variable "bootstrap_custom_data_fw2" {
  description = "base64-encoded init-cfg.txt for FW2 (PAN-OS reads via Azure IMDS userData)"
  type        = string
  sensitive   = true
}

variable "fw_managed_identity_id" {
  description = "User Assigned Managed Identity resource ID attached to FW VMs (future Azure-service auth — Key Vault, Storage, Monitor)"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
