###############################################################################
# Panorama Module
# Palo Alto Panorama - Centralized Management VM
#
# Placement: snet-mgmt (10.0.0.0/24), private IP 10.0.0.10
# Access:    Public IP for HTTPS GUI (443) and SSH (22)
# Storage:   2TB Premium SSD data disk for log storage
# License:   BYOL - auth code applied via custom_data on first boot
###############################################################################

###############################################################################
# Marketplace Agreement for Panorama BYOL
###############################################################################
resource "azurerm_marketplace_agreement" "panorama" {
  publisher = "paloaltonetworks"
  offer     = "panorama"
  plan      = "byol"
}

###############################################################################
# Public IP for Panorama Management
###############################################################################
resource "azurerm_public_ip" "panorama" {
  name                = "pip-panorama-mgmt"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

###############################################################################
# Network Interface
###############################################################################
resource "azurerm_network_interface" "panorama" {
  name                = "nic-panorama-mgmt"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig-panorama"
    subnet_id                     = var.mgmt_subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.panorama_private_ip
    public_ip_address_id          = azurerm_public_ip.panorama.id
    primary                       = true
  }
}

###############################################################################
# Panorama VM
###############################################################################
resource "azurerm_linux_virtual_machine" "panorama" {
  name                            = "vm-panorama"
  location                        = var.location
  resource_group_name             = var.resource_group_name
  size                            = var.vm_size
  admin_username                  = var.admin_username
  admin_password                  = var.admin_password
  disable_password_authentication = false
  tags                            = var.tags

  network_interface_ids = [
    azurerm_network_interface.panorama.id,
  ]

  os_disk {
    name                 = "osdisk-panorama"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 60
  }

  # Panorama BYOL image from Azure Marketplace
  source_image_reference {
    publisher = "paloaltonetworks"
    offer     = "panorama"
    sku       = "byol"
    version   = var.panorama_version
  }

  plan {
    name      = "byol"
    publisher = "paloaltonetworks"
    product   = "panorama"
  }

  # Bootstrap init-cfg for Panorama: sets hostname and auth code
  # Panorama reads custom_data directly (not via storage account)
  custom_data = base64encode(templatefile("${path.module}/templates/panorama-init-cfg.txt.tpl", {
    hostname           = var.panorama_hostname
    panorama_auth_code = var.panorama_auth_code
  }))

  depends_on = [azurerm_marketplace_agreement.panorama]
}

###############################################################################
# Data Disk for Log Storage (2TB)
###############################################################################
resource "azurerm_managed_disk" "panorama_logs" {
  name                 = "disk-panorama-logs"
  location             = var.location
  resource_group_name  = var.resource_group_name
  storage_account_type = "Premium_LRS"
  create_option        = "Empty"
  disk_size_gb         = var.log_disk_size_gb
  tags                 = var.tags
}

resource "azurerm_virtual_machine_data_disk_attachment" "panorama_logs" {
  managed_disk_id    = azurerm_managed_disk.panorama_logs.id
  virtual_machine_id = azurerm_linux_virtual_machine.panorama.id
  lun                = 0
  caching            = "None"
}
