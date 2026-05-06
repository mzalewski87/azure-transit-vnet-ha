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
#   - Ethernet interfaces: eth1/1 (untrust), eth1/2 (trust)
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
  create_dhcp_default_route = false # static routes in VR handle routing
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
  permitted_ips = ["168.63.129.16"] # Azure LB health probe source IP only

  depends_on = [panos_panorama_template.transit]
}

###############################################################################
# Zone Protection Profile (via XML API)
#
# panos 1.x has no native zone-protection-profile resource, so create via XML
# API. Two profiles:
#   Azure-Internet-Protection (untrust) — flood + recon + packet-based attack
#     defenses tuned for internet-facing traffic
#   Azure-Internal-Protection (trust) — packet-based defenses only; no flood
#     thresholds because internal traffic should never produce floods
#
# Numbers are PANW-recommended starting points; tune after observing baseline.
#
# Ref: PANW DoS and Zone Protection Best Practices guide
###############################################################################

resource "null_resource" "zone_protection_profiles" {
  triggers = {
    template_name = panos_panorama_template.transit.name
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -e
      PANORAMA_URL="https://${var.panorama_hostname}:${var.panorama_port}"
      PAN_USER="${var.panorama_username}"
      TEMPLATE_NAME="${panos_panorama_template.transit.name}"

      echo "=== Creating Zone Protection Profiles ==="

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

      ZP_BASE="/config/devices/entry[@name='localhost.localdomain']/template/entry[@name='$TEMPLATE_NAME']/config/devices/entry[@name='localhost.localdomain']/network/profiles/zone-protection-profile"

      # Internet-facing profile (untrust)
      curl -sk --max-time 30 "$PANORAMA_URL/api/" \
        --data-urlencode "type=config" \
        --data-urlencode "action=set" \
        --data-urlencode "xpath=$ZP_BASE/entry[@name='Azure-Internet-Protection']" \
        --data-urlencode "element=<flood><tcp-syn><red><alarm-rate>10000</alarm-rate><activate-rate>15000</activate-rate><maximal-rate>20000</maximal-rate></red></tcp-syn><udp><red><alarm-rate>50000</alarm-rate><activate-rate>100000</activate-rate><maximal-rate>200000</maximal-rate></red></udp><icmp><red><alarm-rate>10000</alarm-rate><activate-rate>20000</activate-rate><maximal-rate>30000</maximal-rate></red></icmp><icmpv6><red><alarm-rate>10000</alarm-rate><activate-rate>20000</activate-rate><maximal-rate>30000</maximal-rate></red></icmpv6><other-ip><red><alarm-rate>10000</alarm-rate><activate-rate>20000</activate-rate><maximal-rate>30000</maximal-rate></red></other-ip></flood><scan><entry name='tcp-port-scan'><action><block><duration>3600</duration></block></action><interval>2</interval><threshold>100</threshold></entry><entry name='udp-port-scan'><action><block><duration>3600</duration></block></action><interval>2</interval><threshold>100</threshold></entry><entry name='host-sweep'><action><block><duration>3600</duration></block></action><interval>2</interval><threshold>100</threshold></entry></scan><discard-strict-source-routing>yes</discard-strict-source-routing><discard-loose-source-routing>yes</discard-loose-source-routing><discard-timestamp>yes</discard-timestamp><discard-record-route>yes</discard-record-route><discard-security>yes</discard-security><discard-stream-id>yes</discard-stream-id><discard-unknown-option>yes</discard-unknown-option><discard-malformed-option>yes</discard-malformed-option><discard-ip-frag>no</discard-ip-frag><discard-icmp-ping-zero-id>yes</discard-icmp-ping-zero-id><discard-icmp-large-packet>yes</discard-icmp-large-packet><discard-tcp-syn-with-data>yes</discard-tcp-syn-with-data><discard-tcp-synack-with-data>yes</discard-tcp-synack-with-data>" \
        --data-urlencode "key=$API_KEY" > /dev/null
      echo "  Profile: Azure-Internet-Protection (untrust)"

      # Internal profile (trust) — packet-based defenses only, no flood thresholds
      curl -sk --max-time 30 "$PANORAMA_URL/api/" \
        --data-urlencode "type=config" \
        --data-urlencode "action=set" \
        --data-urlencode "xpath=$ZP_BASE/entry[@name='Azure-Internal-Protection']" \
        --data-urlencode "element=<discard-strict-source-routing>yes</discard-strict-source-routing><discard-loose-source-routing>yes</discard-loose-source-routing><discard-malformed-option>yes</discard-malformed-option><discard-tcp-syn-with-data>yes</discard-tcp-syn-with-data><discard-tcp-synack-with-data>yes</discard-tcp-synack-with-data>" \
        --data-urlencode "key=$API_KEY" > /dev/null
      echo "  Profile: Azure-Internal-Protection (trust)"

      echo "  [OK] Zone Protection Profiles created"
    SCRIPT
  }

  depends_on = [panos_panorama_template.transit]
}

###############################################################################
# Security Zones (in Template)
# Zone Protection Profile attached so the profile is active immediately when
# the zone is pushed to the firewalls.
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

# Attach Zone Protection Profiles to zones via XML API
# panos_panorama_zone in provider 1.x does not expose zone_protection_profile,
# so we set it via XML config after the zones exist.
resource "null_resource" "zone_protection_attach" {
  triggers = {
    template_name = panos_panorama_template.transit.name
    untrust_zone  = panos_panorama_zone.untrust.name
    trust_zone    = panos_panorama_zone.trust.name
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -e
      PANORAMA_URL="https://${var.panorama_hostname}:${var.panorama_port}"
      PAN_USER="${var.panorama_username}"
      TEMPLATE_NAME="${panos_panorama_template.transit.name}"

      ENC_PASS=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${var.panorama_password}', safe=''))")
      API_KEY=$(curl -sk --max-time 30 \
        "$PANORAMA_URL/api/?type=keygen&user=$PAN_USER&password=$ENC_PASS" 2>/dev/null \
        | python3 -c "
import sys, xml.etree.ElementTree as ET
root = ET.fromstring(sys.stdin.read())
print(root.findtext('.//key',''))
" 2>/dev/null)

      ZONE_BASE="/config/devices/entry[@name='localhost.localdomain']/template/entry[@name='$TEMPLATE_NAME']/config/devices/entry[@name='localhost.localdomain']/vsys/entry[@name='vsys1']/zone"

      curl -sk --max-time 30 "$PANORAMA_URL/api/" \
        --data-urlencode "type=config" \
        --data-urlencode "action=set" \
        --data-urlencode "xpath=$ZONE_BASE/entry[@name='untrust']/network" \
        --data-urlencode "element=<zone-protection-profile>Azure-Internet-Protection</zone-protection-profile>" \
        --data-urlencode "key=$API_KEY" > /dev/null
      echo "  Attached Azure-Internet-Protection -> untrust"

      curl -sk --max-time 30 "$PANORAMA_URL/api/" \
        --data-urlencode "type=config" \
        --data-urlencode "action=set" \
        --data-urlencode "xpath=$ZONE_BASE/entry[@name='trust']/network" \
        --data-urlencode "element=<zone-protection-profile>Azure-Internal-Protection</zone-protection-profile>" \
        --data-urlencode "key=$API_KEY" > /dev/null
      echo "  Attached Azure-Internal-Protection -> trust"
    SCRIPT
  }

  depends_on = [
    null_resource.zone_protection_profiles,
    panos_panorama_zone.untrust,
    panos_panorama_zone.trust,
  ]
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
# DNAT: External LB IP port 80/443 → Apache server 10.112.0.4
#
# CRITICAL: Source NAT must use TRUST interface (ethernet1/2), NOT untrust!
#
# Why: After DNAT, packet exits FW trust interface → VNet peering → Apache.
# Apache responds to the SNAT source IP. If SNAT = untrust IP (10.110.129.x):
#   - Azure routes 10.110.129.0/24 via VNet peering (system route, /16)
#   - SYN-ACK arrives at FW UNTRUST NIC, but session expects it on TRUST
#   - FW drops response → asymmetric routing → connection fails
#
# With SNAT = trust IP (10.110.0.x):
#   - SYN-ACK goes to 10.110.0.x → VNet peering → FW TRUST NIC ✅
#   - FW matches session on correct interface → processes response
#
# Ref: PANW Azure Transit VNet reference architecture
###############################################################################

resource "panos_panorama_nat_rule_group" "inbound" {
  device_group     = panos_panorama_device_group.transit.name
  position_keyword = "top"

  rule {
    name        = "DNAT-Inbound-HTTP-Apache"
    description = "DNAT: External LB port 80 → Apache server Spoke1 (SNAT to trust)"

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
            interface = panos_panorama_ethernet_interface.trust.name
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
    description = "DNAT: External LB port 443 → Apache server Spoke1 port 80 (SNAT to trust)"

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
            interface = panos_panorama_ethernet_interface.trust.name
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

  # PAN-OS security policy with DNAT uses:
  #   source zone = original (untrust - from internet)
  #   destination zone = POST-NAT (trust - where Apache 10.112.0.4 lives)
  #   destination address = PRE-NAT (External LB public IP)
  rule {
    name        = "Allow-Inbound-Web"
    description = "Allow HTTP/HTTPS from internet to Apache server via DNAT"
    type        = "universal"

    source_zones     = [panos_panorama_zone.untrust.name]
    source_addresses = ["any"]
    source_users     = ["any"]
    hip_profiles     = ["any"]

    destination_zones     = [panos_panorama_zone.trust.name]
    destination_addresses = [var.external_lb_public_ip]

    applications = ["web-browsing", "ssl"]
    services     = ["application-default"]
    categories   = ["any"]

    action = "allow"

    log_setting = panos_panorama_log_forwarding_profile.default.name
    log_end     = true
  }

  # East-West rules use App-ID rather than "any" so traffic is identified at
  # Layer 7. The list below is a CONSERVATIVE baseline of App-IDs that are
  # guaranteed to exist in PAN-OS 9.0+ App-ID DB. To extend, verify the App-ID
  # name first:
  #   admin@panorama> show application all | match <name>
  # Adding an invalid App-ID (e.g. "ms-ds-rpc" — that one does NOT exist; the
  # real one is "msrpc-base") fails terraform apply with
  # "application '<x>' is not an allowed keyword". Once an invalid App-ID
  # error fires mid-apply, Panorama's API session can be reset, so a single
  # bad name in this list cascades into spurious "Session timed out" on
  # other parallel resources.
  rule {
    name        = "Allow-East-West-Spoke1-to-Spoke2"
    description = "App-ID-aware east-west: Spoke1 -> Spoke2 (inspected)"
    type        = "universal"

    source_zones     = [panos_panorama_zone.trust.name]
    source_addresses = [var.spoke1_vnet_cidr]
    source_users     = ["any"]
    hip_profiles     = ["any"]

    destination_zones     = [panos_panorama_zone.trust.name]
    destination_addresses = [var.spoke2_vnet_cidr]

    applications = [
      "web-browsing", "ssl", "ssh", "dns", "icmp",
      "kerberos", "ldap", "ms-ds-smb", "msrpc-base",
      "ms-rdp", "ntp-base",
    ]
    services   = ["application-default"]
    categories = ["any"]

    action = "allow"

    log_setting = panos_panorama_log_forwarding_profile.default.name
    log_end     = true
  }

  rule {
    name        = "Allow-East-West-Spoke2-to-Spoke1"
    description = "App-ID-aware east-west: Spoke2 -> Spoke1 (return traffic + DC-initiated)"
    type        = "universal"

    source_zones     = [panos_panorama_zone.trust.name]
    source_addresses = [var.spoke2_vnet_cidr]
    source_users     = ["any"]
    hip_profiles     = ["any"]

    destination_zones     = [panos_panorama_zone.trust.name]
    destination_addresses = [var.spoke1_vnet_cidr]

    applications = [
      "web-browsing", "ssl", "ssh", "dns", "icmp",
      "kerberos", "ldap", "ms-ds-smb", "msrpc-base",
      "ms-rdp", "ntp-base",
    ]
    services   = ["application-default"]
    categories = ["any"]

    action = "allow"

    log_setting = panos_panorama_log_forwarding_profile.default.name
    log_end     = true
  }

  rule {
    name        = "Allow-Outbound-Internet"
    description = "App-ID-aware outbound: spoke VMs -> internet (SNAT applied at FW)"
    type        = "universal"

    source_zones     = [panos_panorama_zone.trust.name]
    source_addresses = ["any"]
    source_users     = ["any"]
    hip_profiles     = ["any"]

    destination_zones     = [panos_panorama_zone.untrust.name]
    destination_addresses = ["any"]

    # Outbound list — guaranteed-valid App-IDs in PAN-OS 11.x.
    # apt-get/yum are MUST-HAVE for cloud-init package install on Linux VMs
    # (Apache spoke server fails to bootstrap without apt-get since PAN-OS
    # App-ID classifies traffic to *.archive.ubuntu.com as 'apt-get', not
    # 'web-browsing' — application-default service then doesn't match).
    # ssl covers HTTPS to APIs/package repos before App-ID resolves further.
    # If something else legitimate gets denied (Monitor -> Traffic, rule =
    # Deny-All), add the resolved App-ID here after verifying it via
    #   admin@panorama> show application all | match <name>
    applications = [
      "web-browsing", "ssl", "dns", "ntp-base", "icmp",
      "apt-get", "yum", "ms-update",
      "github", "git",
    ]
    services   = ["application-default"]
    categories = ["any"]

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
# FW Template: Timezone, NTP, Telemetry, System-level Log Forwarding (XML API)
#
# The panos provider has no native resource for timezone/NTP/telemetry or
# system-level Device > Log Settings in Panorama Templates. We set these via
# XML API config mode calls.
#
# Settings:
#   - Timezone: Europe/Warsaw (CEST/CET)
#   - NTP: 0.europe.pool.ntp.org, 1.europe.pool.ntp.org
#   - Telemetry: EU statistics service enabled
#   - System-level log forwarding to Panorama for log types that are NOT
#     policy-driven: system, config, userid, hipmatch, iptag, globalprotect.
#     Traffic/threat/url logs are handled separately by the per-rule Log
#     Forwarding Profile (panos_panorama_log_forwarding_profile.default).
###############################################################################

resource "null_resource" "fw_template_system_settings" {
  triggers = {
    template_name = panos_panorama_template.transit.name
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -e
      PANORAMA_URL="https://${var.panorama_hostname}:${var.panorama_port}"
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

      # System-level log settings (Templates > Device > Log Settings in GUI)
      # Forward system, config, user-id, hip-match, ip-tag, GlobalProtect logs
      # to Panorama. These are NOT policy-driven and need a match-list at
      # /config/shared/log-settings/<TYPE> in the Template content. This is
      # different from per-rule Log Forwarding Profile (handled by panos
      # provider above) which only covers traffic/threat/url log types.
      #
      # Correct xpath: .../template/entry[@name='X']/config/shared/log-settings/<TYPE>/match-list/entry[@name='send-to-panorama']
      # NOT          : .../deviceconfig/setting/logging/<TYPE>  (that node is for log-quotas, not forwarding)
      LOG_BASE="/config/devices/entry[@name='localhost.localdomain']/template/entry[@name='$TEMPLATE_NAME']/config/shared/log-settings"

      for LOG_TYPE in system config userid hipmatch iptag globalprotect; do
        HTTP_CODE=$(curl -sk --max-time 30 -o /tmp/log_setting_resp.xml -w "%%{http_code}" "$PANORAMA_URL/api/" \
          --data-urlencode "type=config" \
          --data-urlencode "action=set" \
          --data-urlencode "xpath=$LOG_BASE/$LOG_TYPE/match-list/entry[@name='send-to-panorama']" \
          --data-urlencode "element=<send-to-panorama>yes</send-to-panorama><filter>All Logs</filter>" \
          --data-urlencode "key=$API_KEY")
        STATUS=$(python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    print(ET.parse('/tmp/log_setting_resp.xml').getroot().get('status',''))
except Exception:
    print('')
" 2>/dev/null)
        if [ "$HTTP_CODE" = "200" ] && [ "$STATUS" = "success" ]; then
          echo "  Log Settings: $LOG_TYPE → Panorama [OK]"
        else
          echo "  Log Settings: $LOG_TYPE → Panorama [FAIL] (HTTP $HTTP_CODE, status $STATUS)"
          cat /tmp/log_setting_resp.xml 2>/dev/null | head -3
          rm -f /tmp/log_setting_resp.xml
          exit 1
        fi
      done
      rm -f /tmp/log_setting_resp.xml
      echo "  [OK] System-level log forwarding configured (system, config, userid, hipmatch, iptag, globalprotect)"

      echo "  [OK] FW Template system settings applied (will take effect after commit + push)"
    SCRIPT
  }

  depends_on = [
    panos_panorama_template.transit,
    panos_panorama_security_rule_group.transit,
  ]
}

###############################################################################
# Administrative Access Hardening (FW Template)
#
# Password policy + login lockout + idle timeout + audit logging applied to
# every firewall via the Template. Enforces baseline compliance with PANW
# Administrative Access Best Practices regardless of which admin account is
# used to log in.
#
# Custom Admin Roles (security-admin / network-admin / read-only-auditor) are
# NOT defined here — Panorama ships with built-in roles (superuser, superreader,
# deviceadmin, devicereader) that cover the lab's needs. Custom RBAC roles
# require ~200 lines of permission-tree XML each; revisit when production-bound.
###############################################################################

resource "null_resource" "fw_template_admin_hardening" {
  triggers = {
    template_name = panos_panorama_template.transit.name
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -e
      PANORAMA_URL="https://${var.panorama_hostname}:${var.panorama_port}"
      PAN_USER="${var.panorama_username}"
      TEMPLATE_NAME="${panos_panorama_template.transit.name}"

      echo "=== Setting FW Template administrative-access hardening ==="

      ENC_PASS=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${var.panorama_password}', safe=''))")
      API_KEY=$(curl -sk --max-time 30 \
        "$PANORAMA_URL/api/?type=keygen&user=$PAN_USER&password=$ENC_PASS" 2>/dev/null \
        | python3 -c "
import sys, xml.etree.ElementTree as ET
root = ET.fromstring(sys.stdin.read())
print(root.findtext('.//key',''))
" 2>/dev/null)

      if [ -z "$API_KEY" ]; then echo "[ERROR] API key failed"; exit 1; fi

      MGMT_BASE="/config/devices/entry[@name='localhost.localdomain']/template/entry[@name='$TEMPLATE_NAME']/config/devices/entry[@name='localhost.localdomain']/deviceconfig/system"

      # Password complexity (min 12 chars, upper+lower+digit+special, max age 90, history 10)
      curl -sk --max-time 30 "$PANORAMA_URL/api/" \
        --data-urlencode "type=config" \
        --data-urlencode "action=set" \
        --data-urlencode "xpath=$MGMT_BASE/password-complexity" \
        --data-urlencode "element=<enabled>yes</enabled><minimum-length>12</minimum-length><minimum-uppercase-letters>1</minimum-uppercase-letters><minimum-lowercase-letters>1</minimum-lowercase-letters><minimum-numeric-letters>1</minimum-numeric-letters><minimum-special-characters>1</minimum-special-characters><password-history-count>10</password-history-count><minimum-password-lifetime>1</minimum-password-lifetime><expiration-period>90</expiration-period><expiration-warning-period>7</expiration-warning-period><post-expiration-grace-period>3</post-expiration-grace-period><post-expiration-admin-login-count>3</post-expiration-admin-login-count>" \
        --data-urlencode "key=$API_KEY" > /dev/null
      echo "  Password complexity: 12 chars min, upper+lower+digit+special, 90-day rotation"

      # Idle timeout (15 min) + max session count
      curl -sk --max-time 30 "$PANORAMA_URL/api/" \
        --data-urlencode "type=config" \
        --data-urlencode "action=set" \
        --data-urlencode "xpath=$MGMT_BASE/idle-timeout" \
        --data-urlencode "element=15" \
        --data-urlencode "key=$API_KEY" > /dev/null
      echo "  Idle timeout: 15 minutes"

      # Login banner shown on every CLI/GUI login.
      curl -sk --max-time 30 "$PANORAMA_URL/api/" \
        --data-urlencode "type=config" \
        --data-urlencode "action=set" \
        --data-urlencode "xpath=$MGMT_BASE/login-banner" \
        --data-urlencode "element=Authorized access only. All activity is monitored and logged." \
        --data-urlencode "key=$API_KEY" > /dev/null
      echo "  Login banner: set"

      # Failed-login lockout policy. Applies via a SHARED authentication-profile
      # named "default-lockout" that any admin user can reference.
      # Canonical xpath per PAN-OS API guide + verified empirically 2026-05-06
      # — element MUST include `<allow-list>` (mandatory field, otherwise commit
      # fails with: "authentication-profile is invalid: missing 'allow-list'").
      # Use <member>all</member> to permit any user to reference this profile;
      # narrow this in production deployments with named admin accounts.
      AUTHPROF_XPATH="/config/devices/entry[@name='localhost.localdomain']/template/entry[@name='$TEMPLATE_NAME']/config/shared/authentication-profile/entry[@name='default-lockout']"
      curl -sk --max-time 30 "$PANORAMA_URL/api/" \
        --data-urlencode "type=config" \
        --data-urlencode "action=set" \
        --data-urlencode "xpath=$AUTHPROF_XPATH" \
        --data-urlencode "element=<lockout><failed-attempts>5</failed-attempts><lockout-time>30</lockout-time></lockout><method><local-database/></method><allow-list><member>all</member></allow-list>" \
        --data-urlencode "key=$API_KEY" > /dev/null
      echo "  Auth profile 'default-lockout': 5 failed attempts -> 30 min lockout (allow-list: all)"
      echo "  NOTE: per-user assignment (set mgt-config users <NAME> authentication-profile default-lockout)"
      echo "        is left manual — production should bind named admin accounts to this profile via GUI"
      echo "        or via Phase 2a customisation. Built-in panadmin uses local auth without this profile."

      echo "  [OK] Administrative-access hardening applied"
    SCRIPT
  }

  depends_on = [
    panos_panorama_template.transit,
    null_resource.fw_template_system_settings,
  ]
}

###############################################################################
# No PAN-OS HA pair is configured.
#
# The PANW Securing Applications in Azure deployment guide (DEC 2024) does
# NOT configure PAN-OS Active/Passive HA between firewalls in the Azure
# Transit VNet model. Failover is realised by Azure Standard Load Balancer
# health probes:
#   - Internal LB (HA Ports rule, /php/login.php probe) drains an unhealthy
#     FW from the backend pool within seconds — outbound + east-west traffic
#     reroutes to the surviving FW.
#   - External LB does the same on the inbound path.
# Configuration consistency between FW1 and FW2 is enforced by Panorama
# Device Group + Template Stack pushes: every change committed on Panorama
# is pushed to both FWs simultaneously, so they always run identical config.
# See README "Azure-Native HA + Configuration Management via Panorama".
###############################################################################

###############################################################################
# Log Collection — overview of the three pieces that make logs flow
#
# Panorama runs in default Panorama Mode with a 2 TB log disk attached
# (modules/panorama). It is registered as its own local Managed Collector
# (`management-node: yes` in `show log-collector all`). FWs reach Panorama
# at the panorama-server IP set in their bootstrap init-cfg over PAN-OS
# port 3978/TCP. There is no separate M-series Log Collector — Panorama IS
# the LC.
#
# Three load-bearing configurations are required for end-to-end log flow:
#
#  1. Local LC bound to default Collector Group (Phase 2a Step 4b).
#     File: phase2-panorama-config/main.tf, null_resource.panorama_bind_local_lc
#     Without this binding, FWs send logs but the LC has no Collector Group
#     membership for the local Panorama and the GUI Master Node Settings tab
#     is empty (cannot save). The Phase 2a step also runs the dedicated
#     `commit-all log-collector-config log-collector-group default` push —
#     without it, LC stays in "Out of Sync — Ring version mismatch" and
#     incoming logs are rejected.
#
#  2. Per-rule Log Forwarding Profile in Device Group (this file).
#     Resource: panos_panorama_log_forwarding_profile.default
#     Every security rule references it via log_setting=default + log_end=true.
#     This handles policy-driven log types only: traffic, threat, url.
#
#  3. System-level log forwarding in Template (this file, below).
#     Resource: null_resource.fw_template_system_settings
#     Forwards non-policy log types: system, config, userid, hipmatch, iptag,
#     globalprotect. These DO NOT come from rules — they need a match-list
#     under /config/shared/log-settings/<type> in the Template content.
#
# Verify on Panorama after some traffic has flowed:
#   admin@panorama> show log-collector all                       # Config Status: In Sync
#   admin@panorama> show logging-status device <FW_SERIAL>       # Last Log Rcvd ≠ N/A
#   admin@panorama> debug log-collector log-collection-stats show incoming-logs
###############################################################################
