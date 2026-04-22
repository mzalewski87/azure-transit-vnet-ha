###############################################################################
# Panorama Module
# Palo Alto Panorama – Centralized Management (Management VNet, 10.255.0.4)
#
# Placement: snet-management (Management VNet), static IP 10.255.0.4
# Access:    No public IP — access only via Bastion (Management VNet)
#            SSH:  az network bastion ssh --target-resource-id <vm-id>
#                  or (after re-apply with ip_connect_enabled=true): --target-ip-address 10.255.0.4
#            HTTPS: az network bastion tunnel --target-resource-id <vm-id>
# Bootstrap: NONE — Panorama starts without custom_data (default hostname: localhost.localdomain)
#            Hostname, license, Template Stack, Device Group configuration → Phase 2 (XML API)
# License:   BYOL — activation via Phase 2: serial number → commit → request license fetch
# Internet:  Outbound via NAT Gateway (natgw-management) in Management VNet
###############################################################################

###############################################################################
# Marketplace Terms Acceptance – Panorama BYOL (idempotent)
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
# Network Interface (Management VNet – private only, no public IP)
###############################################################################
resource "azurerm_network_interface" "panorama" {
  name                = "nic-panorama-mgmt"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig-panorama"
    subnet_id                     = var.management_subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.panorama_private_ip
    primary                       = true
  }
}

###############################################################################
# Panorama VM (Standard_D16s_v3 — 16 vCPU / 64 GB RAM, min 32 GB for PAN-OS 12.x)
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
    disk_size_gb         = 256
  }

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

  # Panorama starts without custom_data (no bootstrap).
  # Configuration: hostname, license, Template Stack, Device Group → Phase 2 (XML API).
  # Run: cd phase2-panorama-config && terraform apply

  depends_on = [null_resource.accept_panorama_terms]
}

###############################################################################
# Data Disk for Log Storage
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
