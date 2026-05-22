###############################################################################
# Front Door + WordPress LB Rule Module – Variables
###############################################################################

variable "frontdoor_profile_name" {
  description = "Existing AFD profile name (afd-panos-transit) — looked up via data source"
  type        = string
  default     = "afd-panos-transit"
}

variable "frontdoor_resource_group_name" {
  description = "Resource group of the existing AFD profile (typically rg-transit-hub)"
  type        = string
}

variable "external_lb_name" {
  description = "Existing External LB name (lb-external-panos) — for adding the WordPress port 8080 rule"
  type        = string
  default     = "lb-external-panos"
}

variable "external_lb_resource_group_name" {
  description = "Resource group of the existing External LB"
  type        = string
}

variable "external_lb_public_ip" {
  description = "Public IP of the existing External LB (used as AFD origin host name)"
  type        = string
}

variable "wordpress_origin_port" {
  description = "Port on External LB used by AFD origin (must match the new LB rule + Panorama DNAT)"
  type        = number
  default     = 8080
}

variable "endpoint_name" {
  description = "AFD endpoint name (becomes wordpress-XXXX.z01.azurefd.net)"
  type        = string
  default     = "endpoint-panos-wordpress"
}

variable "health_probe_path" {
  description = "HTTP path used for AFD origin health probe — WordPress responds with 200 on /"
  type        = string
  default     = "/"
}

variable "health_probe_interval_seconds" {
  description = "Health probe interval (s)"
  type        = number
  default     = 30
}

variable "tags" {
  description = "Tags applied to AFD child resources"
  type        = map(string)
  default     = {}
}
