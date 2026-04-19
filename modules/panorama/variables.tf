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

variable "mgmt_subnet_id" {
  description = "Management subnet ID where Panorama NIC will be placed"
  type        = string
}

variable "panorama_private_ip" {
  description = "Static private IP for Panorama in management subnet"
  type        = string
  default     = "10.0.0.10"
}

variable "vm_size" {
  description = <<-EOT
    Azure VM size for Panorama. Minimalne wymagania PAN-OS:
    - min: Standard_D8s_v3  (8 vCPU, 32 GB RAM)
    - zalecane: Standard_D16s_v3 (16 vCPU, 64 GB RAM)
    Standard_D4s_v3 (16 GB) jest NIEWYSTARCZAJĄCY – Panorama może crashować.
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

variable "bootstrap_custom_data" {
  description = <<-EOT
    base64-encoded bootstrap pointer do Azure Storage Account.
    Format: storage-account=<name>\nfile-share=<container>\nshare-directory=panorama\naccess-key=<key>
    Generowany przez module.bootstrap (panorama_custom_data output).
    PAN-OS pobiera init-cfg z SA: <container>/panorama/config/init-cfg.txt
    Panorama jest PAN-OS – czyta bootstrap identycznie jak VM-Series FW.
  EOT
  type      = string
  sensitive = true
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
