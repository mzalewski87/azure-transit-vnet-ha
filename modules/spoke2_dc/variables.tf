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

variable "skip_auto_promote" {
  description = <<-EOT
    Pomiń automatyczną promocję DC przez Custom Script Extension.

    Ustaw na TRUE jeśli:
      - DC był już promowany w poprzednim (przerwanym) apply
      - Terraform zwraca błąd "already exists" dla extensions/promote-to-dc
      - Chcesz samodzielnie przeprowadzić promocję przez Azure Bastion

    Gdy true: Terraform nie tworzy ani nie niszczy extension –
    jeśli extension istnieje w Azure, pozostanie bez zmian.
    Jeśli extension nie istnieje, DC NIE będzie automatycznie promowany
    (musisz promować ręcznie przez Bastion).

    UWAGA: Po ustawieniu true i wykonaniu apply możesz przywrócić false
    dopiero po usunięciu extension z Azure lub zaimportowaniu go do state.
  EOT
  type        = bool
  default     = false
}
