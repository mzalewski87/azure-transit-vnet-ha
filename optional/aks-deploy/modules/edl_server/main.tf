###############################################################################
# EDL Server Module
#
# Ubuntu 22.04 VM in a new subnet (snet-edl) of the Management VNet. Hosts:
#   - nginx on port 80, serving /edl/{aks-egress-fqdn.txt, aks-egress-ips.txt}
#   - Python generator script (/opt/aks-edl/generate_aks_edl.py)
#   - systemd timer running daily at 03:17 UTC + on every boot
#
# Why Management VNet (not the new spoke3 AKS VNet):
#   PAN-OS firewalls pull EDLs via their MGMT interface by default (the
#   FW's default service route for "External Dynamic Lists" is the mgmt
#   plane). MGMT VNet ↔ Transit Hub peering already exists, so FW MGMT
#   (10.110.255.x) reaches snet-edl (10.255.2.x) directly. Putting the
#   EDL server in spoke3 would require routing the FW pull traffic through
#   the data plane — extra complexity and self-referential reliance on
#   the rules we're configuring.
#
# Cloud-init pattern mirrors modules/spoke1_app — install nginx + python3
# via an infinite-retry systemd service (edl-bootstrap.service) so the
# server eventually comes up even if outbound apt access is briefly
# blocked. The EDL files themselves are written by the Python generator
# (aks-edl-update.service) which is also infinite-retried via timer.
###############################################################################

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
  }
}

###############################################################################
# Subnet (extends the existing Management VNet)
###############################################################################

resource "azurerm_subnet" "edl" {
  name                 = "snet-edl"
  resource_group_name  = var.resource_group_name
  virtual_network_name = var.management_vnet_name
  address_prefixes     = [var.edl_subnet_cidr]
}

###############################################################################
# NSG — port 80 inbound only from FW MGMT subnet
# This is the primary access control; nginx allow/deny is defence in depth.
###############################################################################

resource "azurerm_network_security_group" "edl" {
  name                = "nsg-edl"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  security_rule {
    name                       = "Allow-FW-MGMT-HTTP"
    description                = "Allow EDL pull from FW management subnet only"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = var.fw_mgmt_subnet_cidr
    destination_address_prefix = "*"
  }

  # SSH from Bastion (any inside MGMT VNet works because Bastion uses its
  # own subnet which is part of the same VNet). Restricted to TCP 22.
  security_rule {
    name                       = "Allow-Bastion-SSH"
    description                = "Allow SSH from Bastion subnet for ops access"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Deny-All-Inbound"
    description                = "Explicit deny — defense in depth"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "edl" {
  subnet_id                 = azurerm_subnet.edl.id
  network_security_group_id = azurerm_network_security_group.edl.id
}

###############################################################################
# Network interface — static IP so the URL in panos_panorama_edl is stable
###############################################################################

resource "azurerm_network_interface" "edl" {
  name                = "nic-edl-server"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig-edl"
    subnet_id                     = azurerm_subnet.edl.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.edl_private_ip
    primary                       = true
  }
}

###############################################################################
# Ubuntu 22.04 LTS VM
#
# Cloud-init writes 5 files + runs a systemd-managed bootstrap that retries
# apt install indefinitely (same race-mitigation pattern as Apache spoke VM).
# Once nginx + python3 are installed, the Python generator is invoked once
# manually then handed off to the timer for periodic refresh.
###############################################################################

resource "azurerm_linux_virtual_machine" "edl" {
  name                            = "vm-edl-server"
  location                        = var.location
  resource_group_name             = var.resource_group_name
  size                            = var.vm_size
  admin_username                  = var.admin_username
  admin_password                  = var.admin_password
  disable_password_authentication = false
  tags                            = var.tags

  network_interface_ids = [azurerm_network_interface.edl.id]

  os_disk {
    name                 = "osdisk-edl-server"
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

  custom_data = base64encode(<<-CLOUDINIT
#cloud-config
# NOTE: install via edl-bootstrap.service with infinite retry — mirrors the
# Apache cloud-init pattern. EDL VM is deployed BEFORE Panorama rules exist
# for it, so its first outbound apt call may be denied. Phase C of the
# optional/aks-deploy/ workflow waits for nginx to respond on port 80, so
# until the first install attempt succeeds Phase C blocks.

write_files:
  - path: /opt/aks-edl/fqdn_base_list.txt
    permissions: '0644'
    content: |
      ${join("\n      ", split("\n", file("${path.module}/files/fqdn_base_list.txt")))}

  - path: /opt/aks-edl/generate_aks_edl.py
    permissions: '0755'
    content: |
      ${join("\n      ", split("\n", file("${path.module}/files/generate_aks_edl.py")))}

  - path: /opt/aks-edl/settings.json
    permissions: '0644'
    content: |
      {
        "region": "${var.aks_region}"
      }

  - path: /etc/nginx/sites-available/edl.conf
    permissions: '0644'
    content: |
      ${join("\n      ", split("\n", replace(file("${path.module}/files/nginx-edl.conf"), "$${MGMT_CIDR}", var.fw_mgmt_subnet_cidr)))}

  - path: /etc/systemd/system/aks-edl-update.service
    permissions: '0644'
    content: |
      ${join("\n      ", split("\n", file("${path.module}/files/aks-edl-update.service")))}

  - path: /etc/systemd/system/aks-edl-update.timer
    permissions: '0644'
    content: |
      ${join("\n      ", split("\n", file("${path.module}/files/aks-edl-update.timer")))}

  - path: /usr/local/sbin/install-edl-server.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      # Install nginx + python3 with infinite retry. Mirrors the Apache pattern
      # from modules/spoke1_app — outbound apt may be blocked until Phase C
      # pushes the FW rules. We exit 0 only after both packages are installed
      # and the EDL files are generated at least once.
      LOG=/var/log/cloud-init-edl.log
      echo "[$(date -Is)] install-edl-server.sh attempt" >> "$LOG"

      if command -v nginx >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
        echo "[$(date -Is)] packages already installed" >> "$LOG"
      else
        if apt-get update >> "$LOG" 2>&1 \
           && DEBIAN_FRONTEND=noninteractive apt-get install -y nginx python3 ca-certificates >> "$LOG" 2>&1; then
          echo "[$(date -Is)] nginx + python3 installed successfully" >> "$LOG"
        else
          echo "[$(date -Is)] apt install FAILED — systemd will retry in 60s" >> "$LOG"
          exit 1
        fi
      fi

      # Disable the default nginx site, enable ours
      rm -f /etc/nginx/sites-enabled/default
      ln -sf /etc/nginx/sites-available/edl.conf /etc/nginx/sites-enabled/edl.conf
      mkdir -p /var/www/html/edl
      chown -R www-data:www-data /var/www/html/edl

      # Generate EDL files now (so the first PAN-OS pull returns 200 with content)
      /usr/bin/python3 /opt/aks-edl/generate_aks_edl.py >> "$LOG" 2>&1 || {
        echo "[$(date -Is)] EDL generation FAILED — nginx still started; PAN-OS gets 503 until next retry" >> "$LOG"
      }

      systemctl enable nginx >> "$LOG" 2>&1 || true
      systemctl restart nginx >> "$LOG" 2>&1 || true

      systemctl daemon-reload
      systemctl enable aks-edl-update.timer >> "$LOG" 2>&1 || true
      systemctl start aks-edl-update.timer >> "$LOG" 2>&1 || true

      echo "[$(date -Is)] edl bootstrap complete" >> "$LOG"
      exit 0

  - path: /etc/systemd/system/edl-bootstrap.service
    permissions: '0644'
    content: |
      [Unit]
      Description=Install nginx + python3 and bootstrap EDL files (infinite retry)
      After=network-online.target
      Wants=network-online.target

      [Service]
      Type=oneshot
      ExecStart=/usr/local/sbin/install-edl-server.sh
      RemainAfterExit=yes
      Restart=on-failure
      RestartSec=60s

      [Install]
      WantedBy=multi-user.target

runcmd:
  - systemctl daemon-reload
  - systemctl enable edl-bootstrap.service
  - systemctl start --no-block edl-bootstrap.service
  - echo "[$(date -Is)] edl-bootstrap.service enabled+started (infinite-retry installer)" >> /var/log/cloud-init-edl.log
CLOUDINIT
  )
}
