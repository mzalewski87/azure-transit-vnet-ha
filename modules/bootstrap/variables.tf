###############################################################################
# Bootstrap Module Variables
# Creates Azure Storage Account with VM-Series bootstrap package
###############################################################################

variable "location" {
  description = "Azure region"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group for bootstrap storage account"
  type        = string
}

variable "panorama_private_ip" {
  description = "Private IP of Panorama VM (used in init-cfg.txt as panorama-server)"
  type        = string
  default     = "10.0.0.10"
}

variable "panorama_template_stack" {
  description = "Panorama Template Stack name"
  type        = string
}

variable "panorama_device_group" {
  description = "Panorama Device Group name"
  type        = string
}

variable "panorama_vm_auth_key" {
  description = "VM Auth Key from Panorama (empty string for Phase 1 deploy)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "fw_auth_code" {
  description = "VM-Series BYOL auth code for license activation"
  type        = string
  sensitive   = true
}

variable "fw1_hostname" {
  description = "Hostname for FW1 in init-cfg.txt"
  type        = string
  default     = "fw1-transit-hub"
}

variable "fw2_hostname" {
  description = "Hostname for FW2 in init-cfg.txt"
  type        = string
  default     = "fw2-transit-hub"
}

variable "allowed_subnet_ids" {
  description = <<-EOT
    Subnet IDs allowed to access the bootstrap storage account via Service Endpoint.
    Must have Microsoft.Storage service endpoint enabled (set in networking module).
    FW VMs access the bootstrap blobs via Managed Identity through these subnets.
  EOT
  type        = list(string)
  default     = []
}

variable "terraform_operator_ips" {
  description = <<-EOT
    List of public IP addresses of machines running terraform apply.
    Required because storage account has network_rules default_action=Deny (Azure Policy).
    Get your IP: curl -s https://api.ipify.org
    Example: ["1.2.3.4"]
    Leave empty [] only if running Terraform from within the Azure VNet.
  EOT
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
