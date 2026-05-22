###############################################################################
# Panorama AKS Rules Module
#
# Extends the existing Panorama Device Group + Template with the objects and
# rules required for AKS egress (per Microsoft docs) and WordPress inbound
# DNAT. Must be applied BEFORE the AKS cluster is created — without these
# rules the cluster creation API requests from AKS-managed nodes (image pulls
# from MCR, Konnectivity tunnel to *.hcp.<region>.azmk8s.io) are denied by
# the FW Deny-All catch-all and the cluster gets stuck in "Creating".
#
# What we add:
#   1. Two EDL objects backed by our nginx server:
#        - AKS-Egress-FQDN  (URL list, refresh hourly) — FQDN allowlist
#        - AKS-Egress-IPs   (IP list,  refresh daily ) — AzureCloud.<region>
#                                                       CIDRs (for UDP 1194 /
#                                                       TCP 9000 Konnectivity)
#   2. Address object AKS-Spoke3-CIDR — spoke3 VNet (source for AKS rules)
#   3. Custom service objects for non-default Konnectivity + WordPress ports
#   4. Three security rules inserted BEFORE Allow-Outbound-Internet:
#        - Allow-AKS-Egress-FQDN
#        - Allow-AKS-Egress-AzureCloud
#        - Allow-Inbound-WordPress
#   5. One DNAT NAT rule: External LB:8080 → AKS ingress 10.114.0.10:80
#   6. commit + commit-all shared-policy push to the FW Device Group
#
# Why position BEFORE Allow-Outbound-Internet:
#   The existing Allow-Outbound-Internet rule has source=any/trust → any/untrust
#   and permits web-browsing+ssl+dns+...+apt-get etc. For AKS traffic we want
#   stricter EDL-based allowlists (FQDN match → only MS endpoints, IP match →
#   only AzureCloud) so traffic that DOESN'T match the EDL falls through to
#   Allow-Outbound-Internet for App-ID based broader filtering. If we put the
#   AKS rules AFTER, Allow-Outbound-Internet would match first and the EDL
#   discipline would never apply.
###############################################################################

terraform {
  required_providers {
    panos = {
      source  = "PaloAltoNetworks/panos"
      version = "~> 1.11"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

###############################################################################
# Spoke3 routes in the existing VR-Internal / VR-External
#
# Without these, FW's VR-Internal has no route back to 10.114.0.0/16 when
# return traffic for AKS-initiated outbound arrives. Symptom: traffic logs
# show `app=incomplete` because FW gets the SYN but the SYN-ACK return is
# dropped — empirically verified on test deploy 2026-05-22.
#
# Mirrors the spoke1/spoke2 routes already in modules/panorama_config:
#   VR-Internal:  route 10.114.0.0/16 → trust gateway (interface ethernet1/2)
#   VR-External:  route 10.114.0.0/16 → next-vr VR-Internal (so any external
#                                       traffic destined to spoke3 is handed
#                                       off to the internal VR for delivery)
###############################################################################

resource "panos_panorama_static_route_ipv4" "int_spoke3" {
  name           = "route-to-spoke3"
  template       = var.template_name_for_routes
  virtual_router = var.vr_internal_name
  destination    = var.aks_spoke_cidr
  next_hop       = var.trust_subnet_gateway
  interface      = var.trust_interface
  metric         = 10
}

resource "panos_panorama_static_route_ipv4" "ext_to_spoke3" {
  name           = "spoke3-via-internal"
  template       = var.template_name_for_routes
  virtual_router = var.vr_external_name
  destination    = var.aks_spoke_cidr
  type           = "next-vr"
  next_hop       = var.vr_internal_name
  metric         = 10
}

###############################################################################
# External Dynamic Lists
###############################################################################

# URL EDL — wildcards supported, e.g. *.hcp.<region>.azmk8s.io/
# The trailing slash on each entry is added by generate_aks_edl.py — without
# it PAN-OS silently fails the wildcard match. See README/aks-rules-structure.
#
# repeat=hourly + repeat_at=minute (0-59). Without repeat_at PAN-OS validation
# fails ("recurring hourly is missing 'at'"), which BLOCKS commit-all to FW
# — entire Panorama push stalls (silent in commit-all "OK with warnings"
# status, only visible via `validate full`). Lesson learned 2026-05-22.
resource "panos_panorama_edl" "aks_fqdn" {
  name         = "AKS-Egress-FQDN"
  device_group = var.device_group_name
  description  = "AKS egress FQDN allowlist (source: learn.microsoft.com/en-us/azure/aks/outbound-rules-control-egress) — served by EDL server in mgmt VNet"
  type         = "url"
  source       = "http://${var.edl_server_ip}/edl/aks-egress-fqdn.txt"
  repeat       = var.fqdn_edl_refresh
  repeat_at    = var.fqdn_edl_refresh == "hourly" ? "07" : null # minute of the hour
}

# IP EDL — CIDRs from Azure Service Tags (AzureCloud.<region>). Required for
# Konnectivity tunnel (UDP 1194 + TCP 9000) where AKS does NOT use FQDNs.
# repeat=daily requires repeat_at as exactly 2 chars (hour 00-23, NOT HH:MM
# — verified empirically 2026-05-22 after "needs to be exactly 2 characters"
# validation error). 03 = 03:00 UTC, just after the EDL server's own 03:17
# regeneration timer fires (so PAN-OS pulls the fresh file).
resource "panos_panorama_edl" "aks_ips" {
  name         = "AKS-Egress-IPs"
  device_group = var.device_group_name
  description  = "Azure Service Tags IPv4 CIDRs for AzureCloud.<region> — regenerated daily from MS JSON download"
  type         = "ip"
  source       = "http://${var.edl_server_ip}/edl/aks-egress-ips.txt"
  repeat       = var.ips_edl_refresh
  repeat_at    = var.ips_edl_refresh == "daily" ? "03" : null # hour 00-23 (no minutes)
}

###############################################################################
# Address + service objects
###############################################################################

resource "panos_panorama_address_object" "aks_spoke" {
  name         = "AKS-Spoke3-CIDR"
  device_group = var.device_group_name
  description  = "Spoke3 (AKS) VNet CIDR — source for AKS egress rules"
  type         = "ip-netmask"
  value        = var.aks_spoke_cidr
}

resource "panos_panorama_address_object" "ext_lb_pip" {
  name         = "External-LB-PIP"
  device_group = var.device_group_name
  description  = "External LB public IP — DNAT pre-NAT destination for WordPress (PAN-OS rules match this BEFORE Azure LB rewrites)"
  type         = "ip-netmask"
  # /32 — single host. panos_panorama_address_object always wants a netmask.
  value = "${var.external_lb_public_ip}/32"
}

# Custom service objects. panos provider 1.11 has no panos_panorama_service_object;
# we use panos_service_object inside the device-group via the device_group argument
# (which the resource exposes). Naming follows existing tcp-port-N / udp-port-N style.
resource "panos_panorama_service_object" "tcp_9000" {
  name             = "tcp-9000-konnectivity"
  device_group     = var.device_group_name
  description      = "TCP 9000 — AKS Konnectivity tunnel (node ↔ API server)"
  protocol         = "tcp"
  destination_port = "9000"
}

resource "panos_panorama_service_object" "udp_1194" {
  name             = "udp-1194-konnectivity-legacy"
  device_group     = var.device_group_name
  description      = "UDP 1194 — AKS Konnectivity legacy OpenVPN fallback (per MS outbound-rules docs)"
  protocol         = "udp"
  destination_port = "1194"
}

resource "panos_panorama_service_object" "tcp_8080" {
  name             = "tcp-8080-wordpress"
  device_group     = var.device_group_name
  description      = "TCP 8080 — External LB → FW → AKS ingress-nginx (WordPress)"
  protocol         = "tcp"
  destination_port = "8080"
}

###############################################################################
# NAT rule — WordPress inbound DNAT
#
# External LB rule on port 8080 (added separately by frontdoor_wordpress module
# attached to the existing LB) forwards traffic to FW untrust NICs. PAN-OS DNAT
# here translates External-LB-PIP:8080 → 10.114.0.10:80 (ingress-nginx internal
# LB in spoke3). SNAT to TRUST interface mirrors the Apache pattern in
# modules/panorama_config — required for symmetric routing.
###############################################################################

resource "panos_panorama_nat_rule_group" "aks_dnat" {
  device_group = var.device_group_name
  # position "top" — inbound DNAT rules must be evaluated before any pre-existing
  # SNAT/east-west NAT rules so the destination match wins. Same pattern as the
  # existing modules/panorama_config NAT group.
  position_keyword = "top"

  rule {
    name        = "DNAT-Inbound-WordPress"
    description = "DNAT: External LB port 8080 → AKS ingress-nginx (WordPress) — SNAT to trust"

    original_packet {
      source_zones          = [var.untrust_zone]
      destination_zone      = var.untrust_zone
      destination_interface = var.untrust_interface
      source_addresses      = ["any"]
      destination_addresses = [panos_panorama_address_object.ext_lb_pip.name]
      service               = panos_panorama_service_object.tcp_8080.name
    }

    translated_packet {
      source {
        # SNAT-to-trust pattern. See modules/panorama_config/main.tf lines
        # 408-420 for the full reasoning — short version: without it, the
        # ingress-nginx response (to the FW untrust IP) comes back via VNet
        # peering on the WRONG FW interface and the session is dropped as
        # asymmetric. SNAT'ing to the FW trust IP makes return traffic
        # arrive on the trust interface where the session lives.
        dynamic_ip_and_port {
          interface_address {
            interface = var.trust_interface
          }
        }
      }
      destination {
        static_translation {
          address = var.aks_ingress_ip
          port    = 80
        }
      }
    }
  }

  depends_on = [
    panos_panorama_address_object.ext_lb_pip,
    panos_panorama_service_object.tcp_8080,
  ]
}

###############################################################################
# Security rules (inserted BEFORE Allow-Outbound-Internet)
###############################################################################

resource "panos_panorama_security_rule_group" "aks_rules" {
  device_group = var.device_group_name

  # position_keyword=before + position_reference=Allow-Outbound-Internet places
  # these rules ABOVE the catch-all outbound rule so EDL-based matching wins.
  # If Allow-Outbound-Internet does not exist yet (Phase 2a not run), apply
  # fails with a clear error — that's by design (prerequisite check).
  position_keyword   = "before"
  position_reference = "Allow-Outbound-Internet"

  rule {
    name        = "Allow-AKS-Egress-FQDN"
    description = "AKS nodes/pods → MS FQDN allowlist via URL Category match (EDL: AKS-Egress-FQDN). PAN-OS treats URL EDL as a custom URL category — applies to HTTP/HTTPS traffic only (which is what AKS control-plane + image pulls actually use)."
    type        = "universal"

    source_zones     = [var.trust_zone]
    source_addresses = [panos_panorama_address_object.aks_spoke.name]
    source_users     = ["any"]
    hip_profiles     = ["any"]

    destination_zones = [var.untrust_zone]
    # destination_addresses=any because URL EDL cannot be used as an address
    # object in PAN-OS — it's only valid as a URL Category. The category
    # match below restricts which destinations are allowed.
    destination_addresses = ["any"]

    # App-IDs cover HTTP/HTTPS only here — DNS/NTP/ICMP from AKS fall through
    # to the broader Allow-Outbound-Internet rule (which has explicit dns +
    # ntp-base + icmp + ping App-IDs). web-browsing covers MCR + ARM + AAD,
    # ssl covers Konnectivity + HTTPS APIs, apt-get covers Ubuntu mirrors.
    # azure-storage-account is what PAN-OS classifies MCR data path traffic
    # as (verified empirically 2026-05-22 — without it traffic hits Deny-All
    # because Allow-Outbound-Internet's App-IDs don't include it). The MS
    # docs technically list mcr.microsoft.com as an FQDN, but the actual
    # data fetch goes to *.blob.core.windows.net (Azure Storage CDN), which
    # PAN-OS App-ID engine recognises and renames.
    applications = [
      "web-browsing", "ssl", "apt-get", "github", "git",
      "azure-storage-account",
    ]
    services = ["application-default"]

    # KEY: URL EDL is referenced as URL Category. The rule only matches when
    # the URL category resolved at L7 equals the EDL name (PAN-OS treats
    # custom URL categories — including URL EDLs — interchangeably here).
    categories = [panos_panorama_edl.aks_fqdn.name]

    action = "allow"

    log_setting = "default-logging"
    log_end     = true
  }

  rule {
    name        = "Allow-AKS-Egress-AzureCloud"
    description = "AKS nodes → AzureCloud.<region> on Konnectivity ports (TCP 9000 + UDP 1194). EDL-driven IP allowlist refreshed daily from Azure Service Tags JSON."
    type        = "universal"

    source_zones     = [var.trust_zone]
    source_addresses = [panos_panorama_address_object.aks_spoke.name]
    source_users     = ["any"]
    hip_profiles     = ["any"]

    destination_zones     = [var.untrust_zone]
    destination_addresses = [panos_panorama_edl.aks_ips.name]

    # No App-ID match — Konnectivity uses a custom protocol; rely on service
    # ports + IP allowlist for granularity.
    applications = ["any"]
    services = [
      panos_panorama_service_object.tcp_9000.name,
      panos_panorama_service_object.udp_1194.name,
    ]
    categories = ["any"]

    action = "allow"

    log_setting = "default-logging"
    log_end     = true
  }

  rule {
    name        = "Allow-Inbound-WordPress"
    description = "Internet → WordPress via External LB DNAT (port 8080 → 10.114.0.10:80). Destination address is PRE-NAT per PAN-OS DNAT semantics."
    type        = "universal"

    source_zones     = [var.untrust_zone]
    source_addresses = ["any"]
    source_users     = ["any"]
    hip_profiles     = ["any"]

    destination_zones     = [var.trust_zone]
    destination_addresses = [panos_panorama_address_object.ext_lb_pip.name]

    applications = ["web-browsing", "ssl"]
    services     = [panos_panorama_service_object.tcp_8080.name]
    categories   = ["any"]

    action = "allow"

    log_setting = "default-logging"
    log_end     = true
  }

  depends_on = [
    panos_panorama_edl.aks_fqdn,
    panos_panorama_edl.aks_ips,
    panos_panorama_address_object.aks_spoke,
    panos_panorama_address_object.ext_lb_pip,
    panos_panorama_service_object.tcp_9000,
    panos_panorama_service_object.udp_1194,
    panos_panorama_service_object.tcp_8080,
    panos_panorama_nat_rule_group.aks_dnat,
  ]
}

###############################################################################
# Commit on Panorama + commit-all to FW Device Group
#
# panos_commit handles the Panorama-side commit. The follow-up commit-all
# shared-policy push (which actually distributes the rules to FW1 + FW2) has
# no native panos provider resource in 1.x — we issue it via XML API using
# the same curl-based pattern as scripts/register-fw-panorama.sh:664-686.
#
# Both must complete BEFORE the aks_cluster module starts creating the AKS
# resource; the optional/aks-deploy root main.tf orchestrates this via
# depends_on.
###############################################################################

###############################################################################
# Commit on Panorama via XML API
#
# panos provider 1.x exposes resources to write config but NOT a `commit`
# resource. The existing phase2-panorama-config uses null_resource + curl
# for the same reason — copy that pattern here for consistency.
#
# This is a regular commit (no `<commit-all>`, no device-targeting): just
# persists the staged config to Panorama. The downstream commit-all
# (next resource) is what actually pushes to the FWs.
###############################################################################

resource "null_resource" "panorama_commit" {
  triggers = {
    # Fire whenever any of the rule/object resources change. Routes MUST be in
    # this list — otherwise terraform sees "no triggers changed" after a route
    # is added on a later apply and skips the commit, leaving the new route in
    # Panorama's candidate config and silently absent from the FWs (verified
    # 2026-05-22 against test deployment).
    rule_grp_id    = panos_panorama_security_rule_group.aks_rules.id
    nat_grp_id     = panos_panorama_nat_rule_group.aks_dnat.id
    edl_fqdn_id    = panos_panorama_edl.aks_fqdn.id
    edl_ips_id     = panos_panorama_edl.aks_ips.id
    route_int_id   = panos_panorama_static_route_ipv4.int_spoke3.id
    route_ext_id   = panos_panorama_static_route_ipv4.ext_to_spoke3.id
    addr_aks_spoke = panos_panorama_address_object.aks_spoke.id
    addr_ext_lb    = panos_panorama_address_object.ext_lb_pip.id
    # Content triggers — terraform won't re-run the commit on a panos
    # resource MODIFY-in-place (resource ID stays the same) so we also key
    # off the actual values that get written into those resources. If the
    # AKS ingress IP or external LB PIP changes, this trigger fires and
    # the commit re-runs.
    content_aks_ingress = var.aks_ingress_ip
    content_ext_lb_pip  = var.external_lb_public_ip
    content_aks_cidr    = var.aks_spoke_cidr
    panorama_url        = "https://${var.panorama_hostname}:${var.panorama_port}"
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -e
      PAN_URL="${self.triggers.panorama_url}/api/"
      PAN_USER="${var.panorama_username}"

      echo "=== Panorama commit (AKS rules + EDL objects) ==="

      ENC_PASS=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${var.panorama_password}', safe=''))")
      PAN_KEY=$(curl -sk --max-time 30 \
        "$PAN_URL?type=keygen&user=$PAN_USER&password=$ENC_PASS" 2>/dev/null \
        | python3 -c "
import sys, xml.etree.ElementTree as ET
root = ET.fromstring(sys.stdin.read())
if root.get('status') != 'success':
    print('ERROR', file=sys.stderr); sys.exit(1)
print(root.findtext('.//key',''))
" 2>&1)

      if [ -z "$PAN_KEY" ] || echo "$PAN_KEY" | grep -q "ERROR"; then
        echo "[ERROR] Panorama API keygen failed — is the Bastion tunnel up on port ${var.panorama_port}?"
        exit 1
      fi

      COMMIT_RESP=$(curl -sk --max-time 180 "$PAN_URL" \
        --data-urlencode "type=commit" \
        --data-urlencode "cmd=<commit></commit>" \
        --data-urlencode "key=$PAN_KEY" 2>/dev/null)

      JOB_ID=$(echo "$COMMIT_RESP" | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read())
    if root.get('status') != 'success':
        msg = root.findtext('.//msg','') or root.findtext('.//line','') or 'unknown'
        print(f'ERROR: {msg}', file=sys.stderr); sys.exit(1)
    print(root.findtext('.//job',''))
except SystemExit:
    raise
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr); sys.exit(1)
" 2>&1)

      if echo "$JOB_ID" | grep -q "ERROR"; then
        echo "[ERROR] Panorama commit submission failed: $JOB_ID"
        exit 1
      fi

      if [ -z "$JOB_ID" ]; then
        echo "  [OK] Panorama commit returned no job id (synchronous / nothing to commit)"
        exit 0
      fi

      echo "  [OK] Panorama commit submitted (job $JOB_ID); polling for completion..."

      for i in $(seq 1 30); do
        sleep 10
        STATUS_RESP=$(curl -sk --max-time 30 "$PAN_URL" \
          --data-urlencode "type=op" \
          --data-urlencode "cmd=<show><jobs><id>$JOB_ID</id></jobs></show>" \
          --data-urlencode "key=$PAN_KEY" 2>/dev/null)

        STATUS=$(echo "$STATUS_RESP" | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read())
    print(root.findtext('.//job/status',''))
except Exception:
    print('')
" 2>/dev/null)

        if [ "$STATUS" = "FIN" ]; then
          RESULT=$(echo "$STATUS_RESP" | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read())
    print(root.findtext('.//job/result',''))
except Exception:
    print('')
" 2>/dev/null)
          echo "  [OK] Panorama commit FIN result=$RESULT"
          [ "$RESULT" = "OK" ] && exit 0
          echo "  [WARN] commit completed with result=$RESULT"
          exit 0
        fi
        echo "  [$i/30] Panorama commit in progress (status=$STATUS) — wait 10s..."
      done

      echo "[ERROR] Panorama commit timed out after 5 min"
      exit 1
    SCRIPT
  }

  depends_on = [
    panos_panorama_security_rule_group.aks_rules,
    panos_panorama_nat_rule_group.aks_dnat,
    panos_panorama_static_route_ipv4.int_spoke3,
    panos_panorama_static_route_ipv4.ext_to_spoke3,
  ]
}

resource "null_resource" "commit_all_to_fws" {
  triggers = {
    # Re-run only when rule contents change (rule names list change triggers).
    rule_names   = "${panos_panorama_security_rule_group.aks_rules.id}|${panos_panorama_nat_rule_group.aks_dnat.id}|${panos_panorama_static_route_ipv4.int_spoke3.id}|${panos_panorama_static_route_ipv4.ext_to_spoke3.id}"
    panorama_url = "https://${var.panorama_hostname}:${var.panorama_port}"
    dg_name      = var.device_group_name
    stack_name   = var.template_stack_name
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -e
      PAN_URL="${self.triggers.panorama_url}/api/"
      PAN_USER="${var.panorama_username}"
      DEVICE_GROUP="${self.triggers.dg_name}"
      TEMPLATE_STACK="${self.triggers.stack_name}"

      echo "=== Pushing Template Stack ($TEMPLATE_STACK) + Device Group ($DEVICE_GROUP) ==="

      ENC_PASS=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${var.panorama_password}', safe=''))")
      PAN_KEY=$(curl -sk --max-time 30 \
        "$PAN_URL?type=keygen&user=$PAN_USER&password=$ENC_PASS" 2>/dev/null \
        | python3 -c "
import sys, xml.etree.ElementTree as ET
root = ET.fromstring(sys.stdin.read())
if root.get('status') != 'success':
    print('ERROR', file=sys.stderr); sys.exit(1)
print(root.findtext('.//key',''))
" 2>&1)

      if [ -z "$PAN_KEY" ] || echo "$PAN_KEY" | grep -q "ERROR"; then
        echo "[ERROR] Panorama API keygen failed — is the Bastion tunnel up on port ${var.panorama_port}?"
        exit 1
      fi

      # Helper: poll a job-id until FIN (timeout 10 min)
      poll_job() {
        local JOB_ID="$1"
        local LABEL="$2"
        for i in $(seq 1 60); do
          sleep 10
          local STATUS_RESP=$(curl -sk --max-time 30 "$PAN_URL" \
            --data-urlencode "type=op" \
            --data-urlencode "cmd=<show><jobs><id>$JOB_ID</id></jobs></show>" \
            --data-urlencode "key=$PAN_KEY" 2>/dev/null)
          local STATUS=$(echo "$STATUS_RESP" | python3 -c "
import sys, xml.etree.ElementTree as ET
try: print(ET.fromstring(sys.stdin.read()).findtext('.//job/status',''))
except: print('')
" 2>/dev/null)
          if [ "$STATUS" = "FIN" ]; then
            local RESULT=$(echo "$STATUS_RESP" | python3 -c "
import sys, xml.etree.ElementTree as ET
try: print(ET.fromstring(sys.stdin.read()).findtext('.//job/result',''))
except: print('')
" 2>/dev/null)
            echo "  [OK] $LABEL FIN result=$RESULT"
            [ "$RESULT" = "OK" ] && return 0
            echo "  [WARN] $LABEL completed with result=$RESULT (check Panorama Task Manager)"
            return 0
          fi
          echo "  [$i/60] $LABEL in progress (status=$STATUS) — wait 10s..."
        done
        echo "  [ERROR] $LABEL timed out after 10 min"
        return 1
      }

      submit_push() {
        local CMD="$1"
        local LABEL="$2"
        local RESP=$(curl -sk --max-time 180 "$PAN_URL" \
          --data-urlencode "type=commit" \
          --data-urlencode "action=all" \
          --data-urlencode "cmd=$CMD" \
          --data-urlencode "key=$PAN_KEY" 2>/dev/null)
        local JOB_ID=$(echo "$RESP" | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read())
    if root.get('status') != 'success':
        msg = root.findtext('.//msg','') or root.findtext('.//line','') or 'unknown'
        print(f'ERROR: {msg}', file=sys.stderr); sys.exit(1)
    print(root.findtext('.//job',''))
except SystemExit:
    raise
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr); sys.exit(1)
" 2>&1)
        if echo "$JOB_ID" | grep -q "ERROR"; then
          echo "[ERROR] $LABEL submission failed: $JOB_ID"
          return 1
        fi
        echo "  [OK] $LABEL submitted (job $JOB_ID)"
        poll_job "$JOB_ID" "$LABEL"
      }

      # Order matters: template-stack first (so VR routes reach FW BEFORE the
      # security/NAT rules that depend on them), then shared-policy.
      submit_push "<commit-all><template-stack><name>$TEMPLATE_STACK</name></template-stack></commit-all>" "Template Stack push" || exit 1

      echo "  Waiting 20s for template push to settle on FWs..."
      sleep 20

      submit_push "<commit-all><shared-policy><device-group><entry name='$DEVICE_GROUP'/></device-group></shared-policy></commit-all>" "Device Group push" || exit 1
      exit 0
    SCRIPT
  }

  depends_on = [null_resource.panorama_commit]
}
