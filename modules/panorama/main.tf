###############################################################################
# Panorama Module
# Palo Alto Panorama - Centralized Management VM
#
# Placement: snet-mgmt (10.0.0.0/24), private IP 10.0.0.10 (statyczny)
# Access:    BRAK publicznego IP – wyłącznie przez Spoke2 Bastion (IpConnect SSH
#            lub Bastion tunnel --target-resource-id dla HTTPS/panos provider)
# Storage:   Premium SSD data disk dla logów (domyślnie 2TB)
# License:   BYOL – auth code z custom_data (panorama-init-cfg.txt.tpl) przy starcie
# Internet:  Outbound przez NAT Gateway (pip-nat-gateway-mgmt) – TCP/UDP działa,
#            ICMP nie jest obsługiwany przez Azure NAT Gateway (ping zawiedzie)
###############################################################################

###############################################################################
# Marketplace Terms Acceptance – Panorama BYOL (idempotent via az CLI)
#
# null_resource zamiast azurerm_marketplace_agreement – patrz komentarz
# w modules/firewall/main.tf dla pełnego wyjaśnienia.
###############################################################################
resource "null_resource" "accept_panorama_terms" {
  triggers = {
    agreement = "paloaltonetworks:panorama:byol"
  }

  provisioner "local-exec" {
    command = "az vm image terms accept --publisher paloaltonetworks --offer panorama --plan byol"
  }
}

###############################################################################
# Network Interface (private only – no public IP)
# Dostęp: Spoke2 Bastion → SSH (IpConnect) lub HTTPS (Bastion tunnel)
# Wychodząca komunikacja: przez NAT Gateway (snet-mgmt) → TCP/UDP do internetu
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
    disk_size_gb         = 256 # Panorama image requires min 224 GB; 256 for headroom
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

  depends_on = [null_resource.accept_panorama_terms]
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
