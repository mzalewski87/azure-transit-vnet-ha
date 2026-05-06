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
  # for this boot — cloud-init does NOT auto-retry on subsequent boots).
  #
  # Earlier fix tried a 5-minute runcmd retry loop. That covered the typical
  # case but FAILED on 2026-05-06 when Phase 2b took >1 hour due to an
  # unrelated commit-validation bug — Apache cloud-init expired all 10
  # attempts and apache2 never installed even after Phase 2b later succeeded.
  #
  # Current pattern: install apache2 via a dedicated systemd service
  # `apache2-bootstrap.service` that retries every 60 seconds INDEFINITELY
  # until apt-get install succeeds, regardless of how long Phase 2b takes.
  # The service exits 0 only when apache2 is installed; on first success
  # it enables apache2.service and starts it. Survives reboots and any
  # arbitrary delay in upstream FW config push.
  custom_data = base64encode(<<-CLOUDINIT
#cloud-config
# NOTE: do NOT use the standard `packages:` directive — see header comment
# in main.tf about the Phase 1b/2b race. Install via apache2-bootstrap.service
# which retries every 60s indefinitely.

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

  - path: /usr/local/sbin/install-apache.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      # Install apache2 with infinite retry. Exits 0 only on success.
      # Service is configured Restart=on-failure with RestartSec=60 so the
      # systemd unit calls us again every 60 s if apt-get fails (typically
      # because the FW data-plane outbound path is not yet up — Phase 2b race).
      LOG=/var/log/cloud-init-apache.log
      echo "[$(date -Is)] install-apache.sh attempt" >> "$LOG"
      if command -v apache2 >/dev/null 2>&1; then
        echo "[$(date -Is)] apache2 already installed — ensuring it is enabled+started" >> "$LOG"
        systemctl enable apache2 >> "$LOG" 2>&1 || true
        systemctl restart apache2 >> "$LOG" 2>&1 || true
        ufw allow 'Apache' >> "$LOG" 2>&1 || true
        exit 0
      fi
      if apt-get update >> "$LOG" 2>&1 \
         && DEBIAN_FRONTEND=noninteractive apt-get install -y apache2 >> "$LOG" 2>&1; then
        echo "[$(date -Is)] apache2 installed successfully" >> "$LOG"
        systemctl enable apache2 >> "$LOG" 2>&1 || true
        systemctl restart apache2 >> "$LOG" 2>&1 || true
        ufw allow 'Apache' >> "$LOG" 2>&1 || true
        exit 0
      fi
      echo "[$(date -Is)] install attempt FAILED — systemd will retry in 60s" >> "$LOG"
      exit 1
  - path: /etc/systemd/system/apache2-bootstrap.service
    permissions: '0644'
    content: |
      [Unit]
      Description=Install apache2 via apt-get with infinite retry
      After=network-online.target
      Wants=network-online.target
      ConditionPathExists=!/usr/sbin/apache2

      [Service]
      Type=oneshot
      ExecStart=/usr/local/sbin/install-apache.sh
      RemainAfterExit=yes
      Restart=on-failure
      RestartSec=60s

      [Install]
      WantedBy=multi-user.target

runcmd:
  - systemctl daemon-reload
  - systemctl enable apache2-bootstrap.service
  - systemctl start --no-block apache2-bootstrap.service
  - echo "[$(date -Is)] apache2-bootstrap.service enabled+started (infinite-retry installer)" >> /var/log/cloud-init-apache.log
  - ufw allow 'Apache' || true
  - echo "[$(date -Is)] apache2 enabled+started, listening on port 80" >> /var/log/cloud-init-apache.log
CLOUDINIT
  )
}
