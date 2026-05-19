variable "spoke2_subscription_id" {
  description = "Azure Subscription ID for Spoke2 (same as in main terraform.tfvars)"
  type        = string
}

variable "spoke2_resource_group_name" {
  description = "Resource group where DC resides (default rg-app2-dc — matches azurerm_resource_group.app2 in root main.tf)"
  type        = string
  default     = "rg-app2-dc"
}

variable "dc_vm_name" {
  description = "Nazwa VM kontrolera domeny (default vm-dc-app2 — matches azurerm_windows_virtual_machine.dc in modules/spoke2_dc/main.tf)"
  type        = string
  default     = "vm-dc-app2"
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
