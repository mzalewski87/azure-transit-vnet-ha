###############################################################################
# Bootstrap Module
# VM-Series FW init-cfg renderer (NOT a Storage Account / File Share)
#
# Approach: PAN-OS 10.0+ reads bootstrap parameters from Azure IMDS, so the
# init-cfg.txt content is base64-encoded and passed to each FW VM as
# custom_data/userData. No SMB upload required.
#
# Why no Azure File Share scaffold:
#   The classic PAN-OS bootstrap on Azure expects an SMB share with files
#   under fw{1,2}/config/init-cfg.txt + fw{1,2}/license/authcodes. In this
#   environment the corporate SSL proxy blocks PUT-with-body to
#   *.file.core.windows.net (both the Terraform Go client and curl return
#   "connection reset"), so no upload could ever complete. The IMDS path
#   bypasses the data plane entirely.
#
# A User Assigned Managed Identity is still created and attached to FW VMs
# so PAN-OS can authenticate to other Azure services (Key Vault, Storage,
# Monitor) when added in the future. It carries no role assignments today.
#
# Ref: https://docs.paloaltonetworks.com/vm-series/11-1/vm-series-deployment/bootstrap-the-vm-series-firewall/bootstrap-the-vm-series-firewall-in-azure
###############################################################################

###############################################################################
# User Assigned Managed Identity (attached to FW VMs)
###############################################################################
resource "azurerm_user_assigned_identity" "bootstrap" {
  name                = "id-panos-bootstrap"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

###############################################################################
# Rendered init-cfg.txt files
# Written to disk so they can be inspected during troubleshooting; the actual
# value passed to each FW is the base64-encoded content (see outputs.tf).
###############################################################################

resource "local_file" "fw1_init_cfg" {
  content = templatefile("${path.module}/templates/init-cfg.txt.tpl", {
    hostname                = "fw1-transit-hub"
    panorama_server         = var.panorama_private_ip
    panorama_template_stack = var.panorama_template_stack
    panorama_device_group   = var.panorama_device_group
    panorama_vm_auth_key    = var.panorama_vm_auth_key
    authcodes               = var.fw_auth_code
  })
  filename = "${path.module}/rendered/fw1-init-cfg.txt"
}

resource "local_file" "fw2_init_cfg" {
  content = templatefile("${path.module}/templates/init-cfg.txt.tpl", {
    hostname                = "fw2-transit-hub"
    panorama_server         = var.panorama_private_ip
    panorama_template_stack = var.panorama_template_stack
    panorama_device_group   = var.panorama_device_group
    panorama_vm_auth_key    = var.panorama_vm_auth_key
    authcodes               = var.fw_auth_code
  })
  filename = "${path.module}/rendered/fw2-init-cfg.txt"
}
