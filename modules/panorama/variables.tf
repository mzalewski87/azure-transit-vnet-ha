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
  description = "Azure VM size for Panorama"
  type        = string
  default     = "Standard_D4s_v3"
}

variable "panorama_version" {
  description = "Panorama image version from Azure Marketplace"
  type        = string
  default     = "latest"
}

variable "panorama_hostname" {
  description = "Hostname for Panorama instance"
  type        = string
  default     = "panorama-transit-hub"
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

variable "panorama_serial_number" {
  description = <<-EOT
    Numer seryjny Panoramy z Palo Alto CSP Portal (Assets → Devices).
    Wymagany do automatycznej aktywacji licencji przy starcie.
    Format: np. "007300014999" lub "007900000111".
    Jeśli pusty (""), Panorama generuje własny serial z fingerprinta VM
    i może wymagać ręcznej aktywacji licencji.
  EOT
  type        = string
  default     = ""
}

variable "panorama_auth_code" {
  description = "Panorama BYOL auth code for license activation"
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
