###############################################################################
# Panorama Config Module
# Configures Panorama via panos Terraform provider
#
# IMPORTANT: This module requires Panorama VM to be RUNNING and ACCESSIBLE
# before applying. Run Phase 1 deploy first, wait ~10 minutes for Panorama
# boot, then run Phase 2 (terraform apply without -target restrictions).
#
# Configuration created:
#   - Template + Template Stack (network config: interfaces, zones, VR, routes)
#   - Device Group (security policy + NAT rules)
#   - Ethernet interfaces: eth1/1 (untrust), eth1/2 (trust), eth1/3 (HA2)
#   - Security zones: untrust, trust
#   - Virtual Router with static routes to Spokes + default internet route
#   - NAT rules: DNAT inbound HTTP/HTTPS → Apache (10.1.0.4)
#   - Security policies: allow inbound web, outbound, east-west, deny all
###############################################################################

terraform {
  required_providers {
    panos = {
      source  = "PaloAltoNetworks/panos"
      version = "~> 1.11"
    }
  }
}

###############################################################################
# Template & Template Stack
# Template holds device-level config: interfaces, zones, virtual router
###############################################################################
resource "panos_panorama_template" "transit" {
  name        = var.template_name
  description = "Azure Transit VNet HA - VM-Series network configuration"
}

resource "panos_panorama_template_stack" "transit" {
  name        = var.template_stack_name
  description = "Template Stack for Transit VNet VM-Series HA pair"
  templates   = [panos_panorama_template.transit.name]

  depends_on = [panos_panorama_template.transit]
}

###############################################################################
# Device Group
# Holds security policies and NAT rules shared across FW1 and FW2
###############################################################################
resource "panos_panorama_device_group" "transit" {
  name        = var.device_group_name
  description = "Azure Transit VNet - VM-Series HA device group"

  depends_on = [panos_panorama_template_stack.transit]
}

###############################################################################
# Ethernet Interfaces (in Template)
###############################################################################

# ethernet1/1 - Untrust (external, faces internet/External LB)
# Azure VM NIC has static IP (set in Terraform). PAN-OS uses DHCP client to
# obtain that exact IP from Azure fabric — deterministic, always matches NIC config.
# Required: NAT rules with interface_address need an IP on the interface.
resource "panos_panorama_ethernet_interface" "untrust" {
  name                      = "ethernet1/1"
  template                  = panos_panorama_template.transit.name
  vsys                      = "vsys1"
  mode                      = "layer3"
  enable_dhcp               = true
  create_dhcp_default_route = false   # static routes in VR handle routing
  comment                   = "Untrust interface - External LB / Internet (DHCP from Azure)"

  depends_on = [panos_panorama_template.transit]
}

# ethernet1/2 - Trust (internal, faces Spoke VNets via Internal LB)
resource "panos_panorama_ethernet_interface" "trust" {
  name                      = "ethernet1/2"
  template                  = panos_panorama_template.transit.name
  vsys                      = "vsys1"
  mode                      = "layer3"
  enable_dhcp               = true
  create_dhcp_default_route = false
  comment                   = "Trust interface - Internal LB / Spoke VNets (DHCP from Azure)"

  depends_on = [panos_panorama_template.transit]
}

# ethernet1/3 - HA2 (data synchronization link)
resource "panos_panorama_ethernet_interface" "ha2" {
  name     = "ethernet1/3"
  template = panos_panorama_template.transit.name
  mode     = "ha"
  comment  = "HA2 data synchronization interface"

  depends_on = [panos_panorama_template.transit]
}

###############################################################################
# Security Zones (in Template)
###############################################################################

resource "panos_panorama_zone" "untrust" {
  name     = "untrust"
  template = panos_panorama_template.transit.name
  vsys     = "vsys1"
  mode     = "layer3"
  interfaces = [
    panos_panorama_ethernet_interface.untrust.name,
  ]

  depends_on = [panos_panorama_ethernet_interface.untrust]
}

resource "panos_panorama_zone" "trust" {
  name     = "trust"
  template = panos_panorama_template.transit.name
  vsys     = "vsys1"
  mode     = "layer3"
  interfaces = [
    panos_panorama_ethernet_interface.trust.name,
  ]

  depends_on = [panos_panorama_ethernet_interface.trust]
}

###############################################################################
# Virtual Router + Static Routes (in Template)
# Gateways are first usable IPs of each subnet (/24 → .1)
###############################################################################

resource "panos_panorama_virtual_router" "default" {
  name     = "default"
  template = panos_panorama_template.transit.name
  interfaces = [
    panos_panorama_ethernet_interface.untrust.name,
    panos_panorama_ethernet_interface.trust.name,
  ]

  depends_on = [
    panos_panorama_ethernet_interface.untrust,
    panos_panorama_ethernet_interface.trust,
  ]
}

# Default route: internet-bound traffic → untrust gateway
resource "panos_panorama_static_route_ipv4" "default_internet" {
  name           = "default-internet"
  template       = panos_panorama_template.transit.name
  virtual_router = panos_panorama_virtual_router.default.name
  destination    = "0.0.0.0/0"
  # Untrust subnet gateway = first host in subnet (10.0.1.1 for 10.0.1.0/24)
  next_hop  = cidrhost(var.untrust_subnet_cidr, 1)
  metric    = 10
  interface = panos_panorama_ethernet_interface.untrust.name

  depends_on = [panos_panorama_virtual_router.default]
}

# Spoke1 route: traffic to Spoke1 → trust gateway
resource "panos_panorama_static_route_ipv4" "spoke1" {
  name           = "route-to-spoke1"
  template       = panos_panorama_template.transit.name
  virtual_router = panos_panorama_virtual_router.default.name
  destination    = var.spoke1_vnet_cidr
  next_hop       = cidrhost(var.trust_subnet_cidr, 1)
  metric         = 10
  interface      = panos_panorama_ethernet_interface.trust.name

  depends_on = [panos_panorama_virtual_router.default]
}

# Spoke2 route: traffic to Spoke2 → trust gateway
resource "panos_panorama_static_route_ipv4" "spoke2" {
  name           = "route-to-spoke2"
  template       = panos_panorama_template.transit.name
  virtual_router = panos_panorama_virtual_router.default.name
  destination    = var.spoke2_vnet_cidr
  next_hop       = cidrhost(var.trust_subnet_cidr, 1)
  metric         = 10
  interface      = panos_panorama_ethernet_interface.trust.name

  depends_on = [panos_panorama_virtual_router.default]
}

###############################################################################
# NAT Rules (in Device Group)
# DNAT: External LB IP port 80/443 → Apache server 10.1.0.4
###############################################################################

resource "panos_panorama_nat_rule_group" "inbound" {
  device_group     = panos_panorama_device_group.transit.name
  position_keyword = "top"

  rule {
    name        = "DNAT-Inbound-HTTP-Apache"
    description = "DNAT: External LB port 80 → Apache server Spoke1 (10.1.0.4)"

    original_packet {
      source_zones          = [panos_panorama_zone.untrust.name]
      destination_zone      = panos_panorama_zone.untrust.name
      destination_interface = panos_panorama_ethernet_interface.untrust.name
      source_addresses      = ["any"]
      destination_addresses = [var.external_lb_public_ip]
      service               = "service-http"
    }

    translated_packet {
      source {
        dynamic_ip_and_port {
          interface_address {
            interface = panos_panorama_ethernet_interface.untrust.name
          }
        }
      }
      destination {
        static_translation {
          address = var.apache_server_ip
          port    = 80
        }
      }
    }
  }

  rule {
    name        = "DNAT-Inbound-HTTPS-Apache"
    description = "DNAT: External LB port 443 → Apache server Spoke1 (10.1.0.4)"

    original_packet {
      source_zones          = [panos_panorama_zone.untrust.name]
      destination_zone      = panos_panorama_zone.untrust.name
      destination_interface = panos_panorama_ethernet_interface.untrust.name
      source_addresses      = ["any"]
      destination_addresses = [var.external_lb_public_ip]
      service               = "service-https"
    }

    translated_packet {
      source {
        dynamic_ip_and_port {
          interface_address {
            interface = panos_panorama_ethernet_interface.untrust.name
          }
        }
      }
      destination {
        static_translation {
          address = var.apache_server_ip
          port    = 443
        }
      }
    }
  }

  rule {
    name        = "SNAT-Outbound"
    description = "SNAT: Outbound internet traffic masquerades as untrust interface IP"

    original_packet {
      source_zones          = [panos_panorama_zone.trust.name]
      destination_zone      = panos_panorama_zone.untrust.name
      source_addresses      = ["any"]
      destination_addresses = ["any"]
      service               = "any"
    }

    translated_packet {
      source {
        dynamic_ip_and_port {
          interface_address {
            interface = panos_panorama_ethernet_interface.untrust.name
          }
        }
      }
      destination {}
    }
  }

  depends_on = [
    panos_panorama_device_group.transit,
    panos_panorama_zone.untrust,
    panos_panorama_zone.trust,
  ]
}

###############################################################################
# Security Rules (in Device Group)
###############################################################################

resource "panos_panorama_security_rule_group" "transit" {
  device_group     = panos_panorama_device_group.transit.name
  position_keyword = "top"

  rule {
    name        = "Allow-Inbound-Web"
    description = "Allow HTTP/HTTPS from internet to Apache server via DNAT"
    type        = "universal"

    source_zones     = [panos_panorama_zone.untrust.name]
    source_addresses = ["any"]
    source_users     = ["any"]
    hip_profiles     = ["any"]

    destination_zones     = [panos_panorama_zone.untrust.name]
    destination_addresses = [var.external_lb_public_ip]

    applications = ["web-browsing", "ssl"]
    services     = ["application-default"]
    categories   = ["any"]

    action = "allow"

    log_end = true
  }

  rule {
    name        = "Allow-East-West-Spoke1-to-Spoke2"
    description = "Allow east-west traffic between Spoke1 and Spoke2 (inspected)"
    type        = "universal"

    source_zones     = [panos_panorama_zone.trust.name]
    source_addresses = [var.spoke1_vnet_cidr]
    source_users     = ["any"]
    hip_profiles     = ["any"]

    destination_zones     = [panos_panorama_zone.trust.name]
    destination_addresses = [var.spoke2_vnet_cidr]

    applications = ["any"]
    services     = ["any"]
    categories   = ["any"]

    action = "allow"

    log_end = true
  }

  rule {
    name        = "Allow-East-West-Spoke2-to-Spoke1"
    description = "Allow east-west traffic from Spoke2 back to Spoke1"
    type        = "universal"

    source_zones     = [panos_panorama_zone.trust.name]
    source_addresses = [var.spoke2_vnet_cidr]
    source_users     = ["any"]
    hip_profiles     = ["any"]

    destination_zones     = [panos_panorama_zone.trust.name]
    destination_addresses = [var.spoke1_vnet_cidr]

    applications = ["any"]
    services     = ["any"]
    categories   = ["any"]

    action = "allow"

    log_end = true
  }

  rule {
    name        = "Allow-Outbound-Internet"
    description = "Allow spoke VMs to reach internet (SNAT applied)"
    type        = "universal"

    source_zones     = [panos_panorama_zone.trust.name]
    source_addresses = ["any"]
    source_users     = ["any"]
    hip_profiles     = ["any"]

    destination_zones     = [panos_panorama_zone.untrust.name]
    destination_addresses = ["any"]

    applications = ["any"]
    services     = ["any"]
    categories   = ["any"]

    action = "allow"

    log_end = true
  }

  rule {
    name        = "Deny-All"
    description = "Explicit deny-all catch-all at bottom"
    type        = "universal"

    source_zones     = ["any"]
    source_addresses = ["any"]
    source_users     = ["any"]
    hip_profiles     = ["any"]

    destination_zones     = ["any"]
    destination_addresses = ["any"]

    applications = ["any"]
    services     = ["any"]
    categories   = ["any"]

    action = "deny"

    log_end = true
  }

  depends_on = [
    panos_panorama_device_group.transit,
    panos_panorama_nat_rule_group.inbound,
  ]
}
