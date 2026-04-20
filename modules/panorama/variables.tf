###############################################################################
# Panorama Module Variables
###############################################################################

variable "location" {
  description = "Azure region"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group for Panorama resources"
  type        = string
}

variable "management_subnet_id" {
  description = "Subnet ID in Management VNet (snet-management) where Panorama NIC is placed"
  type        = string
}

variable "panorama_private_ip" {
  description = "Static private IP for Panorama (in Management VNet snet-management)"
  type        = string
  default     = "10.255.0.4"
}

variable "vm_size" {
  description = <<-EOT
    Azure VM size for Panorama.
    Minimum: Standard_D8s_v3 (8 vCPU, 32 GB RAM)
    Recommended: Standard_D16s_v3 (16 vCPU, 64 GB RAM) for production
  EOT
  type        = string
  default     = "Standard_D16s_v3"
}

variable "panorama_version" {
  description = "Panorama image version from Azure Marketplace"
  type        = string
  default     = "latest"
}

variable "admin_username" {
  description = "Administrator username for Panorama"
  type        = string
}

variable "admin_password" {
  description = "Administrator password for Panorama"
  type        = string
  sensitive   = true
}

variable "log_disk_size_gb" {
  description = "Size of log data disk in GB"
  type        = number
  default     = 2048
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
