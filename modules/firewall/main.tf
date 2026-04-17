###############################################################################
# Firewall Module
# 2x Palo Alto VM-Series (Active/Passive HA)
# PAN-OS 11.1, BYOL, Standard_D8s_v3 (8 vCPU / 32 GB RAM)
#
# NIC order per VM (mandatory for PAN-OS boot):
#   NIC0 (primary) = Management   → snet-mgmt    (eth0)
#   NIC1           = Untrust       → snet-untrust  (ethernet1/1)
#   NIC2           = Trust         → snet-trust    (ethernet1/2)
#   NIC3           = HA2           → snet-ha       (ethernet1/3)
#
# HA1 heartbeat uses management interface (eth0)
# HA2 data sync uses dedicated HA subnet (eth3)
###############################################################################

###############################################################################
# Marketplace Terms Acceptance (idempotent via az CLI)
#
# Dlaczego null_resource zamiast azurerm_marketplace_agreement:
#   azurerm_marketplace_agreement rzuca błąd "already exists" jeśli umowa
#   była już wcześniej zaakceptowana (częściowe apply, manualna akcja).
#   null_resource + az vm image terms accept jest IDEMPOTENTNY – zawsze
#   kończy się sukcesem niezależnie od stanu umowy w Azure.
#
# Wymaga: az CLI zalogowanego do właściwej subskrypcji (az login).
###############################################################################
resource "null_resource" "accept_panos_terms" {
  triggers = {
    # Stały trigger – lokalny-exec uruchamia się tylko raz na pierwszym apply
    agreement = "paloaltonetworks:vmseries-flex:byol"
  }

  provisioner "local-exec" {
    command = "az vm image terms accept --publisher paloaltonetworks --offer vmseries-flex --plan byol"
  }
}

###############################################################################
# Availability Set
# Ensures FW1 and FW2 are on separate fault domains → no single hardware failure
# affects both firewalls simultaneously
###############################################################################
resource "azurerm_availability_set" "fw_avset" {
  name                         = "avset-panos-fw-ha"
  location                     = var.location
  resource_group_name          = var.resource_group_name
  platform_fault_domain_count  = 2
  platform_update_domain_count = 5
  managed                      = true
  tags                         = var.tags
}

###############################################################################
# FW1 - Network Interfaces
###############################################################################

# NIC0 - Management (primary)
# UWAGA: Brak publicznego IP – dostęp wyłącznie przez Hub Azure Bastion
# Wychodząca komunikacja (updates, licencje) przez NAT Gateway na snet-mgmt
resource "azurerm_network_interface" "fw1_mgmt" {
  name                = "nic-fw1-mgmt"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig-fw1-mgmt"
    subnet_id                     = var.mgmt_subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.fw1_mgmt_ip
    primary                       = true
  }
}

# NIC1 - Untrust (internet-facing, connected to External LB backend pool)
# IP forwarding enabled: PAN-OS forwards packets with different destination IPs
resource "azurerm_network_interface" "fw1_untrust" {
  name                           = "nic-fw1-untrust"
  location                       = var.location
  resource_group_name            = var.resource_group_name
  ip_forwarding_enabled          = true
  accelerated_networking_enabled = true
  tags                           = var.tags

  ip_configuration {
    name                          = "ipconfig-fw1-untrust"
    subnet_id                     = var.untrust_subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.fw1_untrust_ip
    primary                       = true
  }
}

# NIC2 - Trust (internal-facing, connected to Internal LB backend pool)
resource "azurerm_network_interface" "fw1_trust" {
  name                           = "nic-fw1-trust"
  location                       = var.location
  resource_group_name            = var.resource_group_name
  ip_forwarding_enabled          = true
  accelerated_networking_enabled = true
  tags                           = var.tags

  ip_configuration {
    name                          = "ipconfig-fw1-trust"
    subnet_id                     = var.trust_subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.fw1_trust_ip
    primary                       = true
  }
}

# NIC3 - HA2 data synchronisation link
resource "azurerm_network_interface" "fw1_ha" {
  name                = "nic-fw1-ha"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig-fw1-ha"
    subnet_id                     = var.ha_subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.fw1_ha_ip
    primary                       = true
  }
}

###############################################################################
# FW2 - Network Interfaces
###############################################################################

# NIC0 - Management (private only – dostęp przez Hub Azure Bastion)
resource "azurerm_network_interface" "fw2_mgmt" {
  name                = "nic-fw2-mgmt"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig-fw2-mgmt"
    subnet_id                     = var.mgmt_subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.fw2_mgmt_ip
    primary                       = true
  }
}

# NIC1 - Untrust
resource "azurerm_network_interface" "fw2_untrust" {
  name                           = "nic-fw2-untrust"
  location                       = var.location
  resource_group_name            = var.resource_group_name
  ip_forwarding_enabled          = true
  accelerated_networking_enabled = true
  tags                           = var.tags

  ip_configuration {
    name                          = "ipconfig-fw2-untrust"
    subnet_id                     = var.untrust_subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.fw2_untrust_ip
    primary                       = true
  }
}

# NIC2 - Trust
resource "azurerm_network_interface" "fw2_trust" {
  name                           = "nic-fw2-trust"
  location                       = var.location
  resource_group_name            = var.resource_group_name
  ip_forwarding_enabled          = true
  accelerated_networking_enabled = true
  tags                           = var.tags

  ip_configuration {
    name                          = "ipconfig-fw2-trust"
    subnet_id                     = var.trust_subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.fw2_trust_ip
    primary                       = true
  }
}

# NIC3 - HA2
resource "azurerm_network_interface" "fw2_ha" {
  name                = "nic-fw2-ha"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig-fw2-ha"
    subnet_id                     = var.ha_subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.fw2_ha_ip
    primary                       = true
  }
}

###############################################################################
# External LB Backend Pool Associations (Untrust NICs)
###############################################################################

resource "azurerm_network_interface_backend_address_pool_association" "fw1_untrust_ext" {
  network_interface_id    = azurerm_network_interface.fw1_untrust.id
  ip_configuration_name   = "ipconfig-fw1-untrust"
  backend_address_pool_id = var.external_lb_backend_pool_id
}

resource "azurerm_network_interface_backend_address_pool_association" "fw2_untrust_ext" {
  network_interface_id    = azurerm_network_interface.fw2_untrust.id
  ip_configuration_name   = "ipconfig-fw2-untrust"
  backend_address_pool_id = var.external_lb_backend_pool_id
}

###############################################################################
# Internal LB Backend Pool Associations (Trust NICs)
###############################################################################

resource "azurerm_network_interface_backend_address_pool_association" "fw1_trust_int" {
  network_interface_id    = azurerm_network_interface.fw1_trust.id
  ip_configuration_name   = "ipconfig-fw1-trust"
  backend_address_pool_id = var.internal_lb_backend_pool_id
}

resource "azurerm_network_interface_backend_address_pool_association" "fw2_trust_int" {
  network_interface_id    = azurerm_network_interface.fw2_trust.id
  ip_configuration_name   = "ipconfig-fw2-trust"
  backend_address_pool_id = var.internal_lb_backend_pool_id
}

###############################################################################
# VM-Series FW1 (Active)
###############################################################################
resource "azurerm_linux_virtual_machine" "fw1" {
  name                            = "vm-panos-fw1"
  location                        = var.location
  resource_group_name             = var.resource_group_name
  size                            = var.vm_size
  availability_set_id             = azurerm_availability_set.fw_avset.id
  admin_username                  = var.admin_username
  admin_password                  = var.admin_password
  disable_password_authentication = false
  tags                            = var.tags

  # NIC order is critical for PAN-OS:
  # Index 0 = management (primary), 1 = untrust, 2 = trust, 3 = ha
  network_interface_ids = [
    azurerm_network_interface.fw1_mgmt.id,
    azurerm_network_interface.fw1_untrust.id,
    azurerm_network_interface.fw1_trust.id,
    azurerm_network_interface.fw1_ha.id,
  ]

  os_disk {
    name                 = "osdisk-fw1"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 60
  }

  # PAN-OS 11.1 BYOL image from Azure Marketplace
  source_image_reference {
    publisher = "paloaltonetworks"
    offer     = "vmseries-flex"
    sku       = "byol"
    version   = var.pan_os_version
  }

  # Required Marketplace plan block for BYOL offer
  plan {
    name      = "byol"
    publisher = "paloaltonetworks"
    product   = "vmseries-flex"
  }

  # Bootstrap: points VM-Series to Azure Storage Account bootstrap package
  # Managed Identity provides secure access without static storage keys
  custom_data = var.bootstrap_custom_data_fw1

  identity {
    type         = "UserAssigned"
    identity_ids = [var.fw_managed_identity_id]
  }

  depends_on = [null_resource.accept_panos_terms]
}

###############################################################################
# VM-Series FW2 (Passive)
###############################################################################
resource "azurerm_linux_virtual_machine" "fw2" {
  name                            = "vm-panos-fw2"
  location                        = var.location
  resource_group_name             = var.resource_group_name
  size                            = var.vm_size
  availability_set_id             = azurerm_availability_set.fw_avset.id
  admin_username                  = var.admin_username
  admin_password                  = var.admin_password
  disable_password_authentication = false
  tags                            = var.tags

  network_interface_ids = [
    azurerm_network_interface.fw2_mgmt.id,
    azurerm_network_interface.fw2_untrust.id,
    azurerm_network_interface.fw2_trust.id,
    azurerm_network_interface.fw2_ha.id,
  ]

  os_disk {
    name                 = "osdisk-fw2"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 60
  }

  source_image_reference {
    publisher = "paloaltonetworks"
    offer     = "vmseries-flex"
    sku       = "byol"
    version   = var.pan_os_version
  }

  plan {
    name      = "byol"
    publisher = "paloaltonetworks"
    product   = "vmseries-flex"
  }

  custom_data = var.bootstrap_custom_data_fw2

  identity {
    type         = "UserAssigned"
    identity_ids = [var.fw_managed_identity_id]
  }

  depends_on = [null_resource.accept_panos_terms]
}
