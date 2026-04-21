###############################################################################
# Bootstrap Module Variables
# Storage Account + FW Bootstrap Package (init-cfg.txt, authcodes)
# UWAGA: Bootstrap SA jest TYLKO dla VM-Series FW.
#        Panorama używa bezpośredniej treści init-cfg w customData (nie SA pointer).
###############################################################################

variable "location" {
  description = "Azure region"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group for Bootstrap Storage Account"
  type        = string
}

variable "panorama_private_ip" {
  description = "Private IP of Panorama (in Management VNet). Used in FW init-cfg as panorama-server="
  type        = string
  default     = "10.255.0.4"
}

variable "panorama_template_stack" {
  description = "Panorama Template Stack name for FW (in FW init-cfg tplname=)"
  type        = string
  default     = "Transit-VNet-Stack"
}

variable "panorama_device_group" {
  description = "Panorama Device Group name for FW (in FW init-cfg dgname=)"
  type        = string
  default     = "Transit-VNet-DG"
}

variable "panorama_vm_auth_key" {
  description = <<-EOT
    Device Registration Auth Key generated in Panorama (Panorama → Devices → VM Auth Key).
    Required for FW to register with Panorama during bootstrap.
    Format: 2:XXXXXXXXXXXXXXXX...
    If empty: FW still bootstraps (license + basic config), but won't register in Panorama
    automatically. Registration will happen via Device Certificate (PAN-OS 12.x) or manually.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "fw_auth_code" {
  description = <<-EOT
    Authorization code for VM-Series FW BYOL license from CSP Portal.
    Format: XXXX-XXXX-XXXX-XXXX
    Used in FW init-cfg authcodes= for automatic license activation.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "allowed_subnet_ids" {
  description = <<-EOT
    List of subnet IDs allowed to access the Bootstrap Storage Account.
    Required for Azure Policy: "Storage accounts should restrict network access"
    Must include: Transit FW mgmt subnet (service endpoint Microsoft.Storage)
    Add Management VNet subnet if Panorama needs SA access (not required for direct init-cfg).
  EOT
  type        = list(string)
  default     = []
}

variable "terraform_operator_ips" {
  description = <<-EOT
    Public IP(s) of the Terraform operator machine(s) for blob upload.
    Required because SA network_rules.default_action = "Deny" (Azure Policy compliance).
    Get your IP: curl -s https://api.ipify.org
    Example: ["203.0.113.10"]
  EOT
  type        = list(string)
  default     = []
}

variable "nat_gateway_ips" {
  description = <<-EOT
    Public IP(s) of NAT Gateways used by FW management subnet (snet-mgmt) for outbound traffic.
    Added to bootstrap SA ip_rules as a reliable fallback when Azure service endpoint routing
    is not ready at FW boot time (service endpoint propagation can take several minutes).
    FW management traffic exits via NAT Gateway with a static public IP. Without this rule,
    the SA's default_action=Deny would block bootstrap SA access during FW first boot.
    Pass: [module.networking.nat_gateway_transit_mgmt_public_ip]
  EOT
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
