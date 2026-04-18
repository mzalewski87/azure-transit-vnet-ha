output "dc_vm_id" {
  description = "ID VM kontrolera domeny"
  value       = data.azurerm_virtual_machine.dc.id
}

output "promotion_status" {
  description = "Status promocji DC (po apply)"
  value       = "DC promotion extension deployed. VM restarts after promotion (~30-45 min)."
}
