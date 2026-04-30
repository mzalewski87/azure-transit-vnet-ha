###############################################################################
# Firewall Module
# 2x Palo Alto VM-Series (Active/Passive HA) — PAN-OS 11.x BYOL.
#
# NIC order per VM (mandatory for PAN-OS boot order):
#   NIC0 (primary) = Management   -> snet-mgmt    (eth0)        HA1 heartbeat
#   NIC1           = Untrust       -> snet-public  (ethernet1/1) Internet-facing
#   NIC2           = Trust         -> snet-private (ethernet1/2) Spoke-facing
#   NIC3           = HA2           -> snet-ha      (ethernet1/3) HA2 state sync
#
# Active/Passive HA itself is configured by Panorama Template (see
# modules/panorama_config/main.tf -> null_resource.fw_template_ha_config) with
# per-FW peer-ip / device-priority overrides applied during Phase 2b.
#
# FW1 host index = 4, FW2 host index = 5 in every subnet (computed via cidrhost).
###############################################################################

locals {
  # Two-FW pair. Order in this list defines which FW is active (first = active,
  # device-priority 100 in HA election) and which is passive (priority 200).
  fw_names = ["fw1", "fw2"]

  # Per-FW custom_data lookup (variables stay separate for backward compatibility
  # with the bootstrap module outputs that produce them).
  fw_custom_data = {
    fw1 = var.bootstrap_custom_data_fw1
    fw2 = var.bootstrap_custom_data_fw2
  }

  # NIC type -> {subnet_id, subnet_cidr, dataplane_flags}
  # Dataplane interfaces (untrust/trust) need IP forwarding + accelerated
  # networking. Mgmt and HA NICs do not.
  nic_types = {
    mgmt    = { subnet_id = var.mgmt_subnet_id, subnet_cidr = var.mgmt_subnet_cidr, dataplane = false }
    untrust = { subnet_id = var.untrust_subnet_id, subnet_cidr = var.untrust_subnet_cidr, dataplane = true }
    trust   = { subnet_id = var.trust_subnet_id, subnet_cidr = var.trust_subnet_cidr, dataplane = true }
    ha      = { subnet_id = var.ha_subnet_id, subnet_cidr = var.ha_subnet_cidr, dataplane = false }
  }

  # Cartesian product of FW x NIC type, keyed "fw1-mgmt", "fw1-untrust", ...
  fw_nics = {
    for combo in setproduct(local.fw_names, keys(local.nic_types)) :
    "${combo[0]}-${combo[1]}" => {
      fw         = combo[0]
      nic_type   = combo[1]
      subnet_id  = local.nic_types[combo[1]].subnet_id
      ip_address = cidrhost(local.nic_types[combo[1]].subnet_cidr, combo[0] == "fw1" ? 4 : 5)
      dataplane  = local.nic_types[combo[1]].dataplane
    }
  }
}

###############################################################################
# Marketplace Terms Acceptance (idempotent via az CLI)
#
# null_resource + `az vm image terms accept` is idempotent — succeeds whether
# the agreement was previously accepted or not. azurerm_marketplace_agreement
# would error with "already exists" on partial applies, hence this approach.
###############################################################################
resource "null_resource" "accept_panos_terms" {
  triggers = {
    agreement = "paloaltonetworks:vmseries-flex:byol"
  }

  provisioner "local-exec" {
    command = "az vm image terms accept --publisher paloaltonetworks --offer vmseries-flex --plan byol"
  }
}

###############################################################################
# Availability Set
# FW1 and FW2 placed on separate fault domains so a single hardware failure
# cannot affect both at once.
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
# Network Interfaces
# 8 NICs total (4 per FW): mgmt, untrust, trust, ha — created via for_each
# over the fw_nics map. Static IPs derived from each subnet CIDR.
###############################################################################
resource "azurerm_network_interface" "fw" {
  for_each = local.fw_nics

  name                           = "nic-${each.value.fw}-${each.value.nic_type}"
  location                       = var.location
  resource_group_name            = var.resource_group_name
  ip_forwarding_enabled          = each.value.dataplane
  accelerated_networking_enabled = each.value.dataplane
  tags                           = var.tags

  ip_configuration {
    name                          = "ipconfig-${each.value.fw}-${each.value.nic_type}"
    subnet_id                     = each.value.subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = each.value.ip_address
    primary                       = true
  }
}

###############################################################################
# LB Backend Pool Associations
#   Untrust NICs -> External LB backend pool (DNAT inbound, SNAT outbound)
#   Trust   NICs -> Internal LB backend pool (HA Ports rule)
###############################################################################
resource "azurerm_network_interface_backend_address_pool_association" "fw_untrust_ext" {
  for_each = toset(local.fw_names)

  network_interface_id    = azurerm_network_interface.fw["${each.key}-untrust"].id
  ip_configuration_name   = "ipconfig-${each.key}-untrust"
  backend_address_pool_id = var.external_lb_backend_pool_id
}

resource "azurerm_network_interface_backend_address_pool_association" "fw_trust_int" {
  for_each = toset(local.fw_names)

  network_interface_id    = azurerm_network_interface.fw["${each.key}-trust"].id
  ip_configuration_name   = "ipconfig-${each.key}-trust"
  backend_address_pool_id = var.internal_lb_backend_pool_id
}

###############################################################################
# VM-Series Virtual Machines
###############################################################################
resource "azurerm_linux_virtual_machine" "fw" {
  for_each = toset(local.fw_names)

  name                            = "vm-panos-${each.key}"
  location                        = var.location
  resource_group_name             = var.resource_group_name
  size                            = var.vm_size
  availability_set_id             = azurerm_availability_set.fw_avset.id
  admin_username                  = var.admin_username
  admin_password                  = var.admin_password
  disable_password_authentication = false
  tags                            = var.tags

  # NIC order is critical for PAN-OS — it maps:
  #   index 0 -> management (must be primary)
  #   index 1 -> ethernet1/1 (untrust)
  #   index 2 -> ethernet1/2 (trust)
  #   index 3 -> ethernet1/3 (HA2)
  network_interface_ids = [
    azurerm_network_interface.fw["${each.key}-mgmt"].id,
    azurerm_network_interface.fw["${each.key}-untrust"].id,
    azurerm_network_interface.fw["${each.key}-trust"].id,
    azurerm_network_interface.fw["${each.key}-ha"].id,
  ]

  os_disk {
    name                 = "osdisk-${each.key}"
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

  # custom_data is set at VM creation time (immutable after). PAN-OS will
  # ALSO read userData via Azure IMDS — and on marketplace VMs with a plan{}
  # block, the user_data argument is silently dropped by the AzureRM provider.
  # See null_resource.fw_set_userdata below for the workaround.
  custom_data = local.fw_custom_data[each.key]

  identity {
    type         = "UserAssigned"
    identity_ids = [var.fw_managed_identity_id]
  }

  depends_on = [null_resource.accept_panos_terms]
}

###############################################################################
# Workaround: set userData via az CLI after VM creation
#
# Bug: azurerm_linux_virtual_machine.user_data is silently dropped by the
# AzureRM provider for marketplace VMs that include a plan{} block. PAN-OS
# 11.x reads bootstrap parameters from Azure IMDS userData (preferred over
# customData), so without this workaround the FW boots with an empty bootstrap
# config and no Panorama registration.
#
# Sequence: deallocate (force-stop before PAN-OS config save) ->
#   az vm update --user-data (single-line base64 — same value as custom_data) ->
#   az vm start (PAN-OS first boot reads userData via IMDS).
#
# TODO (post-deploy verification): retest with current azurerm provider. If a
# future release propagates user_data on marketplace VMs, this null_resource
# can be removed and the user_data argument set directly on the VM resource.
# To verify: comment out this block, set user_data = local.fw_custom_data[each.key]
# on azurerm_linux_virtual_machine.fw, run a fresh deploy, then SSH and check
# `show system bootstrap status`. If still broken, restore the workaround.
###############################################################################
resource "null_resource" "fw_set_userdata" {
  for_each = toset(local.fw_names)

  triggers = {
    vm_id          = azurerm_linux_virtual_machine.fw[each.key].id
    bootstrap_hash = sha256(local.fw_custom_data[each.key])
  }

  provisioner "local-exec" {
    command = "az vm deallocate --ids ${azurerm_linux_virtual_machine.fw[each.key].id} && az vm update --ids ${azurerm_linux_virtual_machine.fw[each.key].id} --user-data '${local.fw_custom_data[each.key]}' && az vm start --ids ${azurerm_linux_virtual_machine.fw[each.key].id}"
  }

  depends_on = [azurerm_linux_virtual_machine.fw]
}
