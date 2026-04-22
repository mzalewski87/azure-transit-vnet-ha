###############################################################################
# optional/dc-promote/
#
# OPTIONAL step — promote Windows Server to Active Directory Domain Controller.
# Run after Phase 1a and Phase 1b completion if you need AD DS.
#
# WYMAGANIA:
#   - DC VM (vm-spoke2-dc) must be running (deployed in Phase 1a)
#   - Bastion tunnel or Azure API access
#
# USAGE:
#   cd optional/dc-promote/
#   cp terraform.tfvars.example terraform.tfvars
#   # Fill in: spoke2_subscription_id, admin_password
#   terraform init
#   terraform apply
#   # Wait 30-45 min for promotion completion and reboot
#
# WERYFIKACJA (przez Azure Bastion → RDP → vm-spoke2-dc):
#   nltest /sc_verify:panw.labs
#   Get-ADDomain | Select Name,DomainMode
#
# AFTER PROMOTION — User-ID Integration:
#   Configure PAN-OS User-ID Agent pointing to DC (10.2.0.4)
#   for user/group-based security policies.
###############################################################################

data "azurerm_virtual_machine" "dc" {
  name                = var.dc_vm_name
  resource_group_name = var.spoke2_resource_group_name
}

###############################################################################
# AD DS Promotion – Custom Script Extension
# Instaluje AD DS i promuje Windows Server do Domain Controller.
# Czas: 30-45 minut (install + reboot po promocji).
###############################################################################
resource "azurerm_virtual_machine_extension" "promote_dc" {
  name                 = "promote-to-dc"
  virtual_machine_id   = data.azurerm_virtual_machine.dc.id
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.10"

  protected_settings = jsonencode({
    commandToExecute = join(" ", [
      "powershell -ExecutionPolicy Unrestricted -Command",
      "\"Install-WindowsFeature -Name AD-Domain-Services,DNS,RSAT-AD-Tools,RSAT-DNS-Server -IncludeManagementTools;",
      "$securePass = ConvertTo-SecureString '${var.admin_password}' -AsPlainText -Force;",
      "Import-Module ADDSDeployment;",
      "Install-ADDSForest",
      "-DomainName '${var.domain_name}'",
      "-DomainNetBIOSName '${upper(split(".", var.domain_name)[0])}'",
      "-SafeModeAdministratorPassword $securePass",
      "-InstallDns:$true",
      "-Force:$true",
      "-NoRebootOnCompletion:$false\"",
    ])
  })

  timeouts {
    create = "60m"
  }

  lifecycle {
    ignore_changes = all
  }
}
