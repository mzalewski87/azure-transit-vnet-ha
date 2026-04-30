###############################################################################
# Bootstrap Module Variables
# Renders init-cfg.txt for each VM-Series FW; output is base64 custom_data.
###############################################################################

variable "location" {
  description = "Azure region"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group for the User Assigned Managed Identity"
  type        = string
}

variable "panorama_private_ip" {
  description = "Private IP of Panorama (Management VNet). Used in init-cfg as panorama-server="
  type        = string
  default     = "10.255.0.4"
}

variable "panorama_template_stack" {
  description = "Panorama Template Stack name (FW init-cfg tplname=)"
  type        = string
  default     = "Transit-VNet-Stack"
}

variable "panorama_device_group" {
  description = "Panorama Device Group name (FW init-cfg dgname=)"
  type        = string
  default     = "Transit-VNet-DG"
}

variable "panorama_vm_auth_key" {
  description = <<-EOT
    Device Registration Auth Key generated on Panorama (Panorama -> Devices -> VM Auth Key).
    Required for FW to register with Panorama during bootstrap.
    Format: 2:XXXXXXXXXXXXXXXX...
    If empty: FW still bootstraps (license + basic config), but does not register
    automatically. Registration must then happen via Device Certificate (PAN-OS 12.x)
    or manually.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "fw_auth_code" {
  description = <<-EOT
    Authorization code for VM-Series FW BYOL license (CSP Portal).
    Format: XXXX-XXXX-XXXX-XXXX
    Used in FW init-cfg authcodes= for automatic license activation.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
