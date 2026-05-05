###############################################################################
# Spoke1 App Module
# Ubuntu 22.04 LTS with Apache2 - Hello World web application
#
# Traffic flow (inbound HTTP/HTTPS):
#   Azure Front Door → External LB (pip-external-lb)
#   → VM-Series FW (PAN-OS DNAT: 80/443 → 10.1.0.4)
#   → [VNet Peering Hub→Spoke1]
#   → Apache server (10.1.0.4:80)
#
# PAN-OS NAT policy to configure after deploy:
#   Source zone: untrust  | Destination zone: untrust
#   Destination address: pip-external-lb
#   Service: HTTP (80) / HTTPS (443)
#   Translated address: 10.1.0.4 (this VM)
#   Translated port: 80
###############################################################################

terraform {
  required_providers {
    azurerm = {
      source                = "hashicorp/azurerm"
      configuration_aliases = [azurerm.spoke1]
    }
  }
}

###############################################################################
# Network Interface
###############################################################################
resource "azurerm_network_interface" "apache" {
  provider            = azurerm.spoke1
  name                = "nic-spoke1-apache"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig-apache"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.private_ip
    primary                       = true
  }
}

###############################################################################
# Apache Hello World VM
###############################################################################
resource "azurerm_linux_virtual_machine" "apache" {
  provider                        = azurerm.spoke1
  name                            = "vm-spoke1-apache"
  location                        = var.location
  resource_group_name             = var.resource_group_name
  size                            = var.vm_size
  admin_username                  = var.admin_username
  admin_password                  = var.admin_password
  disable_password_authentication = false
  tags                            = var.tags

  network_interface_ids = [
    azurerm_network_interface.apache.id,
  ]

  os_disk {
    name                 = "osdisk-spoke1-apache"
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  # cloud-init: install Apache2, enable it, create Hello World page
  # NOTE: #cloud-config MUST be at column 0 (no leading whitespace) or cloud-init ignores the file
  #
  # KNOWN RACE: this Apache VM gets deployed in Phase 1b (root terraform apply
  # for module.app1_app), but its outbound internet path goes through the
  # VM-Series FW data-plane. The FW security policy + NAT that ENABLE that
  # path are pushed by Phase 2b (scripts/register-fw-panorama.sh). On a fresh
  # deploy, cloud-init starts ~2 minutes after VM boot — at that point Phase
  # 2b is usually still running, so apt-get cannot reach azure.archive.ubuntu.com.
  #
  # The standard cloud-init `packages:` directive fails-fast (one apt-get
  # attempt; if it fails, the apache2 package is permanently not installed
  # for this boot — cloud-init does NOT auto-retry on subsequent boots). To
  # avoid this race, we install apache2 via runcmd with an explicit retry loop.
  # Up to 10 attempts at 30 s = 5 min, which covers Phase 2b's typical window.
  custom_data = base64encode(<<-CLOUDINIT
#cloud-config
# NOTE: do NOT use the standard `packages:` directive — see header comment
# in main.tf about the Phase 1b/2b race. Install via runcmd retry loop instead.

write_files:
  - path: /var/www/html/index.html
    owner: www-data:www-data
    permissions: '0644'
    content: |
      <!DOCTYPE html>
      <html lang="en">
      <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Palo Alto Networks - Transit VNet Demo</title>
        <style>
          body { font-family: Arial, sans-serif; margin: 0; background: #f5f5f5; }
          .header { background: #0c3b6e; color: white; padding: 20px 40px; }
          .header h1 { margin: 0; font-size: 24px; }
          .content { padding: 40px; max-width: 800px; margin: auto; }
          .badge { display: inline-block; background: #e31837; color: white;
                   padding: 4px 12px; border-radius: 4px; font-size: 12px;
                   margin-bottom: 20px; }
          .info-box { background: white; border-left: 4px solid #0c3b6e;
                      padding: 20px; margin: 20px 0; border-radius: 4px;
                      box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
          .info-box h3 { margin-top: 0; color: #0c3b6e; }
          code { background: #f0f0f0; padding: 2px 6px; border-radius: 3px; }
        </style>
      </head>
      <body>
        <div class="header">
          <h1>Palo Alto Networks - Azure Transit VNet HA Demo</h1>
        </div>
        <div class="content">
          <span class="badge">HELLO WORLD</span>
          <h2>Apache2 Web Server - Spoke1</h2>
          <div class="info-box">
            <h3>Traffic Path</h3>
            <p>
              Client &rarr;
              Azure Front Door Premium (global anycast) &rarr;
              External LB (pip-external-lb) &rarr;
              VM-Series FW (PAN-OS inspection + DNAT) &rarr;
              This server (${var.private_ip}, Spoke1 VNet)
            </p>
          </div>
          <div class="info-box">
            <h3>Architecture Details</h3>
            <ul>
              <li>VM: <code>vm-spoke1-apache</code> (Ubuntu 22.04 LTS)</li>
              <li>IP: <code>${var.private_ip}</code> (snet-workload, Spoke1)</li>
              <li>Firewall: <code>2x VM-Series 11.1 HA Active/Passive</code></li>
              <li>Managed by: <code>Panorama</code></li>
              <li>Domain: <code>panw.labs</code> (DC in Spoke2)</li>
            </ul>
          </div>
          <p><em>All traffic to this server is inspected by Palo Alto Networks VM-Series.</em></p>
        </div>
      </body>
      </html>

runcmd:
  - |
    # Wait for outbound internet through VM-Series (Phase 2b race) and
    # install apache2. Logs to /var/log/cloud-init-apache.log so the
    # outcome is visible separately from cloud-init's main log.
    LOG=/var/log/cloud-init-apache.log
    echo "[$(date -Is)] starting apache2 install attempts" >> "$LOG"
    for ATTEMPT in $(seq 1 10); do
      if apt-get update >> "$LOG" 2>&1 \
         && DEBIAN_FRONTEND=noninteractive apt-get install -y apache2 >> "$LOG" 2>&1; then
        echo "[$(date -Is)] apache2 installed on attempt $ATTEMPT" >> "$LOG"
        break
      fi
      echo "[$(date -Is)] attempt $ATTEMPT failed (FW outbound path likely not ready); retry in 30s" >> "$LOG"
      sleep 30
    done
    if ! command -v apache2 >/dev/null 2>&1; then
      echo "[$(date -Is)] FATAL: apache2 not installed after 10 attempts (5 min). Phase 2b probably did not complete in time." >> "$LOG"
      exit 1
    fi
  - systemctl enable apache2
  - systemctl restart apache2
  - ufw allow 'Apache' || true
  - echo "[$(date -Is)] apache2 enabled+started, listening on port 80" >> /var/log/cloud-init-apache.log
CLOUDINIT
  )
}
