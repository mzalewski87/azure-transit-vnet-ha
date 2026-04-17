###############################################################################
# Phase 2 – Panorama Configuration Root Module
# Konfiguruje Panoramę przy użyciu providera panos
###############################################################################

module "panorama_config" {
  source = "../modules/panorama_config"

  panorama_hostname  = var.panorama_hostname
  panorama_username  = var.panorama_username
  panorama_password  = var.panorama_password

  template_name       = var.template_name
  template_stack_name = var.template_stack_name
  device_group_name   = var.device_group_name

  trust_subnet_cidr   = var.trust_subnet_cidr
  untrust_subnet_cidr = var.untrust_subnet_cidr
  spoke1_vnet_cidr    = var.spoke1_vnet_cidr
  spoke2_vnet_cidr    = var.spoke2_vnet_cidr

  apache_server_ip      = var.apache_server_ip
  external_lb_public_ip = var.external_lb_public_ip
}
