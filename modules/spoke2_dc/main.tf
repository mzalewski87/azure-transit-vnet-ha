###############################################################################
# Spoke2 DC Module
# Windows Server 2022 – Active Directory Domain Controller (panw.labs)
# Azure Bastion – Secure RDP access without public IP on DC
#
# Access path:
#   Azure Portal → Bastion → RDP to vm-spoke2-dc (10.2.0.4)
#   No public IP on DC, no VPN required for management access
#
# User-ID integration:
#   After DC is promoted, configure PAN-OS User-ID Agent pointing to DC
#   for User-ID based security policies (user/group to IP mapping)
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
# Domain Controller NIC (no public IP – access via Bastion only)
###############################################################################
resource "azurerm_network_interface" "dc" {
  provider            = azurerm.spoke2
  name                = "nic-spoke2-dc"
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
# Windows Server 2022 Domain Controller VM
###############################################################################
resource "azurerm_windows_virtual_machine" "dc" {
  provider            = azurerm.spoke2
  name                = "vm-spoke2-dc"
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
    name                 = "osdisk-spoke2-dc"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 128
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-datacenter-g2"
    version   = "latest"
  }
}

###############################################################################
# AD DS Promotion Script (Custom Script Extension)
# Installs AD DS role and promotes Windows Server to Domain Controller
# Domain: panw.labs (configurable via var.domain_name)
###############################################################################
resource "azurerm_virtual_machine_extension" "dc_promote" {
  provider             = azurerm.spoke2
  name                 = "promote-to-dc"
  virtual_machine_id   = azurerm_windows_virtual_machine.dc.id
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.10"
  tags                 = var.tags

  # PowerShell script runs inline via protected_settings
  # 1. Install AD DS + DNS + RSAT tools
  # 2. Create new AD forest with domain panw.labs
  # 3. Reboot after promotion (extension handles reboot)
  protected_settings = jsonencode({
    commandToExecute = join("; ", [
      "powershell -ExecutionPolicy Unrestricted -Command \"",
      "Install-WindowsFeature -Name AD-Domain-Services,DNS,RSAT-AD-Tools,RSAT-DNS-Server -IncludeManagementTools;",
      "$securePass = ConvertTo-SecureString '${var.admin_password}' -AsPlainText -Force;",
      "Import-Module ADDSDeployment;",
      "Install-ADDSForest",
      "  -DomainName '${var.domain_name}'",
      "  -DomainNetBIOSName '${upper(split(".", var.domain_name)[0])}'",
      "  -SafeModeAdministratorPassword $securePass",
      "  -InstallDns:$true",
      "  -Force:$true",
      "  -NoRebootOnCompletion:$false",
      "\""
    ])
  })

  timeouts {
    create = "60m" # AD DS promotion + forest creation can take 30-45 min
  }

  depends_on = [azurerm_windows_virtual_machine.dc]
}

###############################################################################
# Azure Bastion Public IP
###############################################################################
resource "azurerm_public_ip" "bastion" {
  provider            = azurerm.spoke2
  name                = "pip-bastion-spoke2"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

###############################################################################
# Azure Bastion Host (Standard SKU)
# Standard allows RDP/SSH via browser and native client
###############################################################################
resource "azurerm_bastion_host" "spoke2" {
  provider            = azurerm.spoke2
  name                = "bastion-spoke2"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "Standard"
  # Enable copy-paste, file transfer and native client (RDP app) support
  copy_paste_enabled     = true
  file_copy_enabled      = true
  tunneling_enabled      = true
  shareable_link_enabled = false
  tags                   = var.tags

  ip_configuration {
    name                 = "ipconfig-bastion"
    subnet_id            = var.bastion_subnet_id
    public_ip_address_id = azurerm_public_ip.bastion.id
  }
}
