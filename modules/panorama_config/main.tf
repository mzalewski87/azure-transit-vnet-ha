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
  management_profile        = panos_panorama_management_profile.health_probe.name
  comment                   = "Untrust interface - External LB / Internet (DHCP from Azure)"

  depends_on = [panos_panorama_template.transit, panos_panorama_management_profile.health_probe]
}

# ethernet1/2 - Trust (internal, faces Spoke VNets via Internal LB)
resource "panos_panorama_ethernet_interface" "trust" {
  name                      = "ethernet1/2"
  template                  = panos_panorama_template.transit.name
  vsys                      = "vsys1"
  mode                      = "layer3"
  enable_dhcp               = true
  create_dhcp_default_route = false
  management_profile        = panos_panorama_management_profile.health_probe.name
  comment                   = "Trust interface - Internal LB / Spoke VNets (DHCP from Azure)"

  depends_on = [panos_panorama_template.transit, panos_panorama_management_profile.health_probe]
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
# Interface Management Profile (in Template)
# Enables HTTPS on data plane interfaces for Azure LB health probes.
# LB probes HTTPS /php/login.php on port 443 — PAN-OS responds with HTTP 200
# when the management plane is ready on that interface.
# Ref: https://github.com/PaloAltoNetworks/azure-terraform-vmseries-fast-ha-failover
###############################################################################

resource "panos_panorama_management_profile" "health_probe" {
  name          = "Azure-Health-Probe"
  template      = panos_panorama_template.transit.name
  https         = true
  permitted_ips = ["168.63.129.16"]  # Azure LB health probe source IP only

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
# Multi-Virtual Router Architecture (in Template)
#
# Required for Azure LB sandwich topology: both External and Internal LBs
# use 168.63.129.16 as health probe source. With a single VR, the ILB probe
# response exits via the untrust gateway (asymmetric) → Azure drops it.
#
# Solution: Two VRs, each with their own 168.63.129.16/32 route pointing
# to their own gateway → symmetric health probe responses on both interfaces.
#
# Inter-VR routing connects VR-External ↔ VR-Internal for data traffic.
#
# Ref: PANW KB kA14u000000saSxCAI
# Ref: https://github.com/PaloAltoNetworks/terraform-azurerm-swfw-modules
###############################################################################

# VR-External: untrust interface (ethernet1/1) — faces External LB + internet
resource "panos_panorama_virtual_router" "external" {
  name     = "VR-External"
  template = panos_panorama_template.transit.name
  interfaces = [
    panos_panorama_ethernet_interface.untrust.name,
  ]

  depends_on = [panos_panorama_ethernet_interface.untrust]
}

# VR-External: default route → internet via untrust gateway
resource "panos_panorama_static_route_ipv4" "ext_default" {
  name           = "default-internet"
  template       = panos_panorama_template.transit.name
  virtual_router = panos_panorama_virtual_router.external.name
  destination    = "0.0.0.0/0"
  next_hop       = cidrhost(var.untrust_subnet_cidr, 1)
  metric         = 10
  interface      = panos_panorama_ethernet_interface.untrust.name

  depends_on = [panos_panorama_virtual_router.external]
}

# VR-External: Azure health probe return → untrust gateway (symmetric)
resource "panos_panorama_static_route_ipv4" "ext_azure_probe" {
  name           = "Azure-Probe-Return"
  template       = panos_panorama_template.transit.name
  virtual_router = panos_panorama_virtual_router.external.name
  destination    = "168.63.129.16/32"
  next_hop       = cidrhost(var.untrust_subnet_cidr, 1)
  metric         = 10
  interface      = panos_panorama_ethernet_interface.untrust.name

  depends_on = [panos_panorama_virtual_router.external]
}

# VR-External: spoke1 traffic → forward to VR-Internal (inter-VR)
resource "panos_panorama_static_route_ipv4" "ext_to_spoke1" {
  name           = "spoke1-via-internal"
  template       = panos_panorama_template.transit.name
  virtual_router = panos_panorama_virtual_router.external.name
  destination    = var.spoke1_vnet_cidr
  type           = "next-vr"
  next_hop       = panos_panorama_virtual_router.internal.name
  metric         = 10

  depends_on = [panos_panorama_virtual_router.external, panos_panorama_virtual_router.internal]
}

# VR-External: spoke2 traffic → forward to VR-Internal (inter-VR)
resource "panos_panorama_static_route_ipv4" "ext_to_spoke2" {
  name           = "spoke2-via-internal"
  template       = panos_panorama_template.transit.name
  virtual_router = panos_panorama_virtual_router.external.name
  destination    = var.spoke2_vnet_cidr
  type           = "next-vr"
  next_hop       = panos_panorama_virtual_router.internal.name
  metric         = 10

  depends_on = [panos_panorama_virtual_router.external, panos_panorama_virtual_router.internal]
}

# VR-Internal: trust interface (ethernet1/2) — faces Internal LB + spokes
resource "panos_panorama_virtual_router" "internal" {
  name     = "VR-Internal"
  template = panos_panorama_template.transit.name
  interfaces = [
    panos_panorama_ethernet_interface.trust.name,
  ]

  depends_on = [panos_panorama_ethernet_interface.trust]
}

# VR-Internal: Azure health probe return → trust gateway (symmetric)
resource "panos_panorama_static_route_ipv4" "int_azure_probe" {
  name           = "Azure-Probe-Return"
  template       = panos_panorama_template.transit.name
  virtual_router = panos_panorama_virtual_router.internal.name
  destination    = "168.63.129.16/32"
  next_hop       = cidrhost(var.trust_subnet_cidr, 1)
  metric         = 10
  interface      = panos_panorama_ethernet_interface.trust.name

  depends_on = [panos_panorama_virtual_router.internal]
}

# VR-Internal: spoke1 traffic → trust gateway
resource "panos_panorama_static_route_ipv4" "int_spoke1" {
  name           = "route-to-spoke1"
  template       = panos_panorama_template.transit.name
  virtual_router = panos_panorama_virtual_router.internal.name
  destination    = var.spoke1_vnet_cidr
  next_hop       = cidrhost(var.trust_subnet_cidr, 1)
  metric         = 10
  interface      = panos_panorama_ethernet_interface.trust.name

  depends_on = [panos_panorama_virtual_router.internal]
}

# VR-Internal: spoke2 traffic → trust gateway
resource "panos_panorama_static_route_ipv4" "int_spoke2" {
  name           = "route-to-spoke2"
  template       = panos_panorama_template.transit.name
  virtual_router = panos_panorama_virtual_router.internal.name
  destination    = var.spoke2_vnet_cidr
  next_hop       = cidrhost(var.trust_subnet_cidr, 1)
  metric         = 10
  interface      = panos_panorama_ethernet_interface.trust.name

  depends_on = [panos_panorama_virtual_router.internal]
}

# VR-Internal: default route → forward to VR-External (inter-VR, for internet)
resource "panos_panorama_static_route_ipv4" "int_default" {
  name           = "Default-Route-to-External"
  template       = panos_panorama_template.transit.name
  virtual_router = panos_panorama_virtual_router.internal.name
  destination    = "0.0.0.0/0"
  type           = "next-vr"
  next_hop       = panos_panorama_virtual_router.external.name
  metric         = 10

  depends_on = [panos_panorama_virtual_router.internal, panos_panorama_virtual_router.external]
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
# Log Forwarding Profile (in Device Group)
# Required for FW traffic logs to reach Panorama.
# Without this, log_end=true in rules only logs locally on FW — not forwarded.
###############################################################################

resource "panos_panorama_log_forwarding_profile" "default" {
  name         = "default-logging"
  device_group = panos_panorama_device_group.transit.name
  description  = "Forward all logs to Panorama log collector"

  match_list {
    name             = "traffic-to-panorama"
    log_type         = "traffic"
    send_to_panorama = true
    filter           = "All Logs"
  }

  match_list {
    name             = "threat-to-panorama"
    log_type         = "threat"
    send_to_panorama = true
    filter           = "All Logs"
  }

  match_list {
    name             = "url-to-panorama"
    log_type         = "url"
    send_to_panorama = true
    filter           = "All Logs"
  }

  depends_on = [panos_panorama_device_group.transit]
}

###############################################################################
# Security Rules (in Device Group)
# All rules use log_setting = Log Forwarding Profile to send logs to Panorama
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

    log_setting = panos_panorama_log_forwarding_profile.default.name
    log_end     = true
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

    log_setting = panos_panorama_log_forwarding_profile.default.name
    log_end     = true
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

    log_setting = panos_panorama_log_forwarding_profile.default.name
    log_end     = true
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

    log_setting = panos_panorama_log_forwarding_profile.default.name
    log_end     = true
  }

  # Azure LB health probes come from 168.63.129.16 on port 443 (HTTPS).
  # In sandwich topology, probes hit BOTH untrust and trust interfaces.
  # Without this rule, probes are denied by Deny-All → LB marks FWs unhealthy.
  # Ref: https://knowledgebase.paloaltonetworks.com/KCSArticleDetail?id=kA14u000000saSxCAI
  rule {
    name        = "Allow-Azure-LB-Probes"
    description = "Allow Azure LB health probes (168.63.129.16) on HTTPS port 443"
    type        = "universal"

    source_zones     = ["any"]
    source_addresses = ["168.63.129.16"]
    source_users     = ["any"]
    hip_profiles     = ["any"]

    destination_zones     = ["any"]
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

    log_setting = panos_panorama_log_forwarding_profile.default.name
    log_end     = true
  }

  depends_on = [
    panos_panorama_device_group.transit,
    panos_panorama_nat_rule_group.inbound,
    panos_panorama_log_forwarding_profile.default,
  ]
}

###############################################################################
# FW Template: Timezone, NTP, Telemetry (via XML API)
#
# The panos provider has no native resource for timezone/NTP/telemetry in
# Panorama Templates. We set these via XML API config mode calls targeting
# the Template's deviceconfig/system path.
#
# Settings:
#   - Timezone: Europe/Warsaw (CEST/CET)
#   - NTP: 0.europe.pool.ntp.org, 1.europe.pool.ntp.org
#   - Telemetry: EU statistics service enabled
###############################################################################

resource "null_resource" "fw_template_system_settings" {
  triggers = {
    template_name = panos_panorama_template.transit.name
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -e
      PANORAMA_URL="https://${var.panorama_hostname}:44300"
      PAN_USER="${var.panorama_username}"
      TEMPLATE_NAME="${panos_panorama_template.transit.name}"

      echo "=== Setting FW Template system settings (timezone, NTP, telemetry) ==="

      ENC_PASS=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${var.panorama_password}', safe=''))")
      API_KEY=$(curl -sk --max-time 30 \
        "$PANORAMA_URL/api/?type=keygen&user=$PAN_USER&password=$ENC_PASS" 2>/dev/null \
        | python3 -c "
import sys, xml.etree.ElementTree as ET
root = ET.fromstring(sys.stdin.read())
if root.get('status') != 'success':
    print('ERROR', file=sys.stderr); sys.exit(1)
print(root.findtext('.//key',''))
" 2>&1)

      if [ -z "$API_KEY" ] || echo "$API_KEY" | grep -q "ERROR"; then
        echo "[ERROR] API key failed"; exit 1
      fi

      # XPath for Template deviceconfig/system
      TPL_XPATH="/config/devices/entry[@name='localhost.localdomain']/template/entry[@name='$TEMPLATE_NAME']/config/devices/entry[@name='localhost.localdomain']/deviceconfig/system"

      # Timezone
      curl -sk --max-time 30 "$PANORAMA_URL/api/" \
        --data-urlencode "type=config" \
        --data-urlencode "action=set" \
        --data-urlencode "xpath=$TPL_XPATH" \
        --data-urlencode "element=<timezone>Europe/Warsaw</timezone>" \
        --data-urlencode "key=$API_KEY" > /dev/null
      echo "  Timezone: Europe/Warsaw"

      # NTP
      curl -sk --max-time 30 "$PANORAMA_URL/api/" \
        --data-urlencode "type=config" \
        --data-urlencode "action=set" \
        --data-urlencode "xpath=$TPL_XPATH/ntp-servers" \
        --data-urlencode "element=<primary-ntp-server><ntp-server-address>0.europe.pool.ntp.org</ntp-server-address></primary-ntp-server><secondary-ntp-server><ntp-server-address>1.europe.pool.ntp.org</ntp-server-address></secondary-ntp-server>" \
        --data-urlencode "key=$API_KEY" > /dev/null
      echo "  NTP: 0.europe.pool.ntp.org, 1.europe.pool.ntp.org"

      # Telemetry (EU statistics service)
      curl -sk --max-time 30 "$PANORAMA_URL/api/" \
        --data-urlencode "type=config" \
        --data-urlencode "action=set" \
        --data-urlencode "xpath=$TPL_XPATH/update-schedule/statistics-service" \
        --data-urlencode "element=<application-reports>yes</application-reports><threat-prevention-reports>yes</threat-prevention-reports><threat-prevention-pcap>yes</threat-prevention-pcap><passive-dns-monitoring>yes</passive-dns-monitoring><url-reports>yes</url-reports><health-performance-reports>yes</health-performance-reports><file-identification-reports>yes</file-identification-reports>" \
        --data-urlencode "key=$API_KEY" > /dev/null
      echo "  Telemetry: EU statistics service enabled"

      # System-level log settings (Device > Log Settings)
      # Forward system, config, user-id, hip-match logs to Panorama
      # These are separate from policy-based logs (handled by Log Forwarding Profile)
      LOG_XPATH="$TPL_XPATH/../../../vsys/entry[@name='vsys1']/log-settings"

      for LOG_TYPE in system config userid hipmatch; do
        echo "  Log Settings: $LOG_TYPE → Panorama"
        curl -sk --max-time 30 "$PANORAMA_URL/api/" \
          --data-urlencode "type=config" \
          --data-urlencode "action=set" \
          --data-urlencode "xpath=/config/devices/entry[@name='localhost.localdomain']/template/entry[@name='$TEMPLATE_NAME']/config/devices/entry[@name='localhost.localdomain']/deviceconfig/setting/logging/$LOG_TYPE" \
          --data-urlencode "element=<match-list><entry name='send-to-panorama'><send-to-panorama>yes</send-to-panorama><filter>All Logs</filter></entry></match-list>" \
          --data-urlencode "key=$API_KEY" > /dev/null 2>&1 || true
      done
      echo "  [OK] System-level log forwarding configured (system, config, userid, hipmatch)"

      echo "  [OK] FW Template system settings applied (will take effect after commit + push)"
    SCRIPT
  }

  depends_on = [
    panos_panorama_template.transit,
    panos_panorama_security_rule_group.transit,
  ]
}
