###############################################################################
# Phase 2 Outputs
###############################################################################

output "template_name" {
  description = "Panorama Template name"
  value       = module.panorama_config.template_name
}

output "template_stack_name" {
  description = "Panorama Template Stack name – przypisz FW1 i FW2 do tego stack'a"
  value       = module.panorama_config.template_stack_name
}

output "device_group_name" {
  description = "Panorama Device Group name – przypisz FW1 i FW2 do tej grupy"
  value       = module.panorama_config.device_group_name
}
