###############################################################################
# Load Balancer Module Variables
###############################################################################

variable "location" {
  description = "Azure region"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group for load balancer resources"
  type        = string
}

variable "untrust_subnet_id" {
  description = "Untrust subnet ID (used for External LB frontend - optional if using public IP only)"
  type        = string
}

variable "trust_subnet_id" {
  description = "Trust subnet ID for Internal LB frontend private IP"
  type        = string
}

variable "external_lb_public_ip_id" {
  description = "Public IP resource ID for External LB frontend"
  type        = string
}

variable "internal_lb_private_ip" {
  description = "Static private IP address for Internal LB frontend (must be in trust subnet)"
  type        = string
  default     = "10.0.2.100"
}

variable "health_probe_port" {
  description = "TCP port used by LB health probes to check VM-Series liveness"
  type        = number
  default     = 22
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
