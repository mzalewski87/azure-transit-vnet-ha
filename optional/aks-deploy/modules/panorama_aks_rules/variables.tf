###############################################################################
# Panorama AKS Rules Module – Variables
###############################################################################

variable "panorama_hostname" {
  description = "Panorama hostname (127.0.0.1 when using a Bastion tunnel)"
  type        = string
  default     = "127.0.0.1"
}

variable "panorama_port" {
  description = "Panorama HTTPS port (44300 when using the Bastion tunnel pattern of phase2-panorama-config)"
  type        = number
  default     = 44300
}

variable "panorama_username" {
  description = "Panorama admin username"
  type        = string
  default     = "panadmin"
}

variable "panorama_password" {
  description = "Panorama admin password (sensitive)"
  type        = string
  sensitive   = true
}

variable "device_group_name" {
  description = "Existing Device Group name (must match phase2-panorama-config output)"
  type        = string
  default     = "Transit-VNet-DG"
}

variable "template_name" {
  description = "Existing Template name (where address/service objects are not strictly needed but referenced in DG inheritance)"
  type        = string
  default     = "Transit-VNet-Template"
}

variable "untrust_zone" {
  description = "Untrust zone name (must match existing modules/panorama_config zone)"
  type        = string
  default     = "untrust"
}

variable "trust_zone" {
  description = "Trust zone name (must match existing modules/panorama_config zone)"
  type        = string
  default     = "trust"
}

variable "untrust_interface" {
  description = "Untrust interface name (for NAT original_packet destination_interface)"
  type        = string
  default     = "ethernet1/1"
}

variable "trust_interface" {
  description = "Trust interface name (for SNAT-to-trust on AKS DNAT)"
  type        = string
  default     = "ethernet1/2"
}

variable "template_name_for_routes" {
  description = "Existing Template name where the VR static routes for spoke3 will be added (must match modules/panorama_config)"
  type        = string
  default     = "Transit-VNet-Template"
}

variable "template_stack_name" {
  description = "Existing Template Stack name (for commit-all template-stack push after adding routes)"
  type        = string
  default     = "Transit-VNet-Stack"
}

variable "vr_internal_name" {
  description = "Existing VR-Internal name (modules/panorama_config)"
  type        = string
  default     = "VR-Internal"
}

variable "vr_external_name" {
  description = "Existing VR-External name (modules/panorama_config)"
  type        = string
  default     = "VR-External"
}

variable "trust_subnet_gateway" {
  description = "Gateway IP on the trust subnet (used as next-hop for VR-Internal route to spoke3). Typically cidrhost(snet-private, 1) = 10.110.0.1"
  type        = string
  default     = "10.110.0.1"
}

variable "edl_server_ip" {
  description = "Private IP of the EDL nginx server (source URL for panos_panorama_edl)"
  type        = string
}

variable "aks_spoke_cidr" {
  description = "Spoke3 VNet CIDR (matches AzureCloud.<region> in destination of AKS egress rule)"
  type        = string
}

variable "aks_ingress_ip" {
  description = "Internal LB IP of ingress-nginx in AKS (DNAT destination for WordPress inbound). MUST be inside snet-aks-ilb."
  type        = string
  default     = "10.114.1.4"
}

variable "external_lb_public_ip" {
  description = "Public IP of the existing External LB (source for WordPress DNAT and AFD route origin)"
  type        = string
}

variable "wordpress_inbound_port" {
  description = "External port on External LB used for WordPress (non-conflicting with Apache on 80/443)"
  type        = number
  default     = 8080
}

variable "fqdn_edl_refresh" {
  description = "Refresh interval for the FQDN EDL (PAN-OS keywords: five-minute, hourly, daily, weekly, monthly)"
  type        = string
  default     = "hourly"
}

variable "ips_edl_refresh" {
  description = "Refresh interval for the IP EDL"
  type        = string
  default     = "daily"
}

variable "tags" {
  description = "Tags applied to PAN-OS objects via description fields"
  type        = map(string)
  default     = {}
}
