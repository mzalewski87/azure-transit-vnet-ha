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

variable "vm_series_auto_registration_pin_id" {
  description = <<-EOT
    VM-Series Auto-Registration PIN ID from CSP Portal (Assets -> Device
    Certificates -> Generate Registration PIN). Together with vm_series_auto_
    registration_pin_value, this becomes vm-series-auto-registration-pin-id=
    in init-cfg.txt and lets the FW auto-register with PANW licensing service
    AND fetch its device certificate on FIRST BOOT — no post-boot API call
    needed (which would not work anyway because the FW serial is unknown
    pre-deploy, so per-serial OTPs cannot be pre-generated).
    The same PIN is shared across all FWs in your CSP account; PINs are NOT
    serial-specific (unlike OTPs). Empty = skip device cert auto-fetch (lab
    deployments without Strata cloud features).
    Ref: VM-Series Deployment Guide v11.1, pages 178-181.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "vm_series_auto_registration_pin_value" {
  description = <<-EOT
    Companion to vm_series_auto_registration_pin_id. PIN value from same CSP
    Portal generation flow. Both must be non-empty for the init-cfg lines to
    be emitted (template has a guard).
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
