###############################################################################
# Panorama Config Module Outputs
###############################################################################

output "template_name" {
  description = "Panorama Template name"
  value       = panos_panorama_template.transit.name
}

output "template_stack_name" {
  description = "Panorama Template Stack name (assign to FW devices in Panorama)"
  value       = panos_panorama_template_stack.transit.name
}

output "device_group_name" {
  description = "Panorama Device Group name (assign to FW devices in Panorama)"
  value       = panos_panorama_device_group.transit.name
}
