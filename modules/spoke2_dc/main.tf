###############################################################################
# Spoke2 DC Module
# Windows Server 2022 Domain Controller
#
# Placement: App2 VNet snet-workload (10.113.0.0/24), static IP 10.113.0.4
# Access:    Azure Bastion Standard (Management VNet) — IpConnect or RDP
#            Bastion Standard supports VMs in peered VNets
# Domain:    panw.labs (configuration via cloud-init PowerShell)
#
# NOTE: Bastion is in Management VNet (module.networking), NOT here.
###############################################################################

terraform {
  required_providers {
    azurerm = {
      source                = "hashicorp/azurerm"
      configuration_aliases = [azurerm.spoke2]
    }
  }
}

###############################################################################
# Network Interface
###############################################################################
resource "azurerm_network_interface" "dc" {
  provider            = azurerm.spoke2
  name                = "nic-dc-workload"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig-dc"
    subnet_id                     = var.workload_subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.dc_private_ip
    primary                       = true
  }
}

###############################################################################
# Windows Server 2022 VM (Domain Controller)
###############################################################################
resource "azurerm_windows_virtual_machine" "dc" {
  provider            = azurerm.spoke2
  name                = "vm-dc-app2"
  location            = var.location
  resource_group_name = var.resource_group_name
  size                = var.dc_vm_size
  admin_username      = var.admin_username
  admin_password      = var.admin_password
  tags                = var.tags

  network_interface_ids = [
    azurerm_network_interface.dc.id,
  ]

  os_disk {
    name                 = "osdisk-dc"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 128
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-Datacenter"
    version   = "latest"
  }

  # Active Directory Domain Services installation + promotion (if not skipped)
  custom_data = var.skip_auto_promote ? null : base64encode(templatefile("${path.module}/dc-setup.ps1.tpl", {
    domain_name    = var.domain_name
    admin_password = var.admin_password
  }))
}

###############################################################################
# DC Setup Script placeholder
# If skip_auto_promote = true (default), promote via optional/dc-promote module
###############################################################################
