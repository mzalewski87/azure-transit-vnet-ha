###############################################################################
# WordPress Module – Outputs
###############################################################################

output "ingress_internal_lb_ip" {
  description = "Internal LB IP serving the ingress-nginx controller (DNAT target on the FW)"
  value       = var.ingress_internal_lb_ip
}

output "ingress_namespace" {
  description = "Kubernetes namespace for the ingress controller"
  value       = helm_release.ingress_nginx.namespace
}

output "wordpress_namespace" {
  description = "Kubernetes namespace for WordPress"
  value       = helm_release.wordpress.namespace
}

output "wordpress_admin_username" {
  description = "WordPress admin username"
  value       = var.wp_admin_username
}
