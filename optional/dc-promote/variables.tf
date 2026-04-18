variable "spoke2_subscription_id" {
  description = "Azure Subscription ID dla Spoke2 (ta sama co w głównym terraform.tfvars)"
  type        = string
}

variable "spoke2_resource_group_name" {
  description = "Resource group gdzie jest DC (domyślnie rg-spoke2-dc)"
  type        = string
  default     = "rg-spoke2-dc"
}

variable "dc_vm_name" {
  description = "Nazwa VM kontrolera domeny"
  type        = string
  default     = "vm-spoke2-dc"
}

variable "admin_password" {
  description = "Hasło administratora DC (to samo co dc_admin_password w głównym tfvars)"
  type        = string
  sensitive   = true
}

variable "domain_name" {
  description = "Nazwa domeny AD (np. panw.labs)"
  type        = string
  default     = "panw.labs"
}
