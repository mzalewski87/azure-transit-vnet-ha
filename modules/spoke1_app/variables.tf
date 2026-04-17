###############################################################################
# Spoke1 App Module Variables
# Ubuntu VM with Apache2 Hello World web server
###############################################################################

variable "location" {
  description = "Azure region"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group for Spoke1 app server"
  type        = string
}

variable "subnet_id" {
  description = "Spoke1 workload subnet ID"
  type        = string
}

variable "private_ip" {
  description = "Static private IP for Apache server"
  type        = string
  default     = "10.1.0.4"
}

variable "vm_size" {
  description = "Azure VM size for Apache server"
  type        = string
  default     = "Standard_D2s_v3" # Standard_B2s not available in all regions
}

variable "admin_username" {
  description = "Administrator username"
  type        = string
  default     = "apacheadmin"
}

variable "admin_password" {
  description = "Administrator password"
  type        = string
  sensitive   = true
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
