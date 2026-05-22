###############################################################################
# WordPress Module – Variables
###############################################################################

variable "ingress_internal_lb_ip" {
  description = "Static IP for the AKS internal LB (ingress-nginx frontend) — MUST be inside snet-aks-ilb (10.114.1.0/27), NOT snet-aks-nodes, because that's where Azure provisions the LB frontend per the annotation. Must also match the Panorama DNAT target."
  type        = string
  default     = "10.114.1.4"
}

variable "ingress_subnet_name" {
  description = "Subnet name for the internal LB frontend (annotation azure-load-balancer-internal-subnet)"
  type        = string
  default     = "snet-aks-ilb"
}

variable "wp_admin_username" {
  description = "WordPress admin username"
  type        = string
  default     = "wpadmin"
}

variable "wp_admin_password" {
  description = "WordPress admin password (sensitive)"
  type        = string
  sensitive   = true
}

variable "wp_blog_name" {
  description = "WordPress blog title"
  type        = string
  default     = "PANW Demo – AKS WordPress"
}

variable "wordpress_chart_version" {
  description = "Bitnami WordPress Helm chart version (pin for reproducibility)"
  type        = string
  default     = "23.0.0"
}

variable "ingress_nginx_chart_version" {
  description = "ingress-nginx Helm chart version"
  type        = string
  default     = "4.10.0"
}
