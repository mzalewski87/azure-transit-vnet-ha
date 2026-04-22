variable "spoke2_subscription_id" {
  description = "Azure Subscription ID for Spoke2 (same as in main terraform.tfvars)"
  type        = string
}

variable "spoke2_resource_group_name" {
  description = "Resource group where DC resides (default rg-spoke2-dc)"
  type        = string
  default     = "rg-spoke2-dc"
}

variable "dc_vm_name" {
  description = "Nazwa VM kontrolera domeny"
  type        = string
  default     = "vm-spoke2-dc"
}

variable "admin_password" {
  description = "DC administrator password (same as dc_admin_password in main tfvars)"
  type        = string
  sensitive   = true
}

variable "domain_name" {
  description = "Nazwa domeny AD (np. panw.labs)"
  type        = string
  default     = "panw.labs"
}
