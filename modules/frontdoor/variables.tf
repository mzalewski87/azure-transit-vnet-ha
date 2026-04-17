###############################################################################
# Front Door Module Variables
###############################################################################

variable "resource_group_name" {
  description = "Resource group for Azure Front Door resources"
  type        = string
}

variable "frontdoor_sku" {
  description = "Azure Front Door SKU tier"
  type        = string
  default     = "Premium_AzureFrontDoor"

  validation {
    condition     = contains(["Standard_AzureFrontDoor", "Premium_AzureFrontDoor"], var.frontdoor_sku)
    error_message = "frontdoor_sku must be 'Standard_AzureFrontDoor' or 'Premium_AzureFrontDoor'."
  }
}

variable "external_lb_public_ip" {
  description = "Public IP address of the External Load Balancer (Front Door origin)"
  type        = string
}

variable "health_probe_path" {
  description = "HTTP path used for Front Door origin health probe"
  type        = string
  default     = "/"
}

variable "health_probe_interval_seconds" {
  description = "Interval in seconds between Front Door health probes"
  type        = number
  default     = 30
}

variable "origin_http_port" {
  description = "HTTP port on the origin (External LB / VM-Series)"
  type        = number
  default     = 80
}

variable "origin_https_port" {
  description = "HTTPS port on the origin"
  type        = number
  default     = 443
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
