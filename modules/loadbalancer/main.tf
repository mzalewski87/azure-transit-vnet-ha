###############################################################################
# Load Balancer Module
#
# External (Public) Standard LB:
#   - Frontend: Public IP (pip-external-lb)
#   - Backend:  FW1 + FW2 Untrust NICs
#   - Rules:    TCP 80 (HTTP) + TCP 443 (HTTPS)
#   - NOTE:     "All Ports" (HA Ports protocol=All) is NOT allowed on public LBs
#               Only internal LBs support HA Ports (Azure restriction)
#   - Outbound: SNAT rule for internet egress
#
# Internal Standard LB:
#   - Frontend: Static private IP in Trust subnet (10.0.2.100)
#   - Backend:  FW1 + FW2 Trust NICs
#   - Rule:     HA Ports (protocol=All, port=0) — required for next-hop LB pattern
#   - UDR in Spokes points 0.0.0.0/0 → this frontend IP
#
# Both LBs use Standard SKU (required for zone-redundancy and HA Ports)
###############################################################################

###############################################################################
# External (Public) Load Balancer
###############################################################################

resource "azurerm_lb" "external" {
  name                = "lb-external-panos"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "Standard"
  tags                = var.tags

  frontend_ip_configuration {
    name                 = "fe-external-lb"
    public_ip_address_id = var.external_lb_public_ip_id
  }
}

resource "azurerm_lb_backend_address_pool" "external" {
  name            = "bep-external-panos"
  loadbalancer_id = azurerm_lb.external.id
}

# Health probe - checks VM-Series SSH port to determine firewall liveness
# When FW fails, Azure LB stops sending traffic to that instance
resource "azurerm_lb_probe" "external" {
  name                = "probe-fw-ssh"
  loadbalancer_id     = azurerm_lb.external.id
  protocol            = "Tcp"
  port                = var.health_probe_port
  interval_in_seconds = 5
  number_of_probes    = 2
}

# HTTP rule – forwards port 80 to VM-Series untrust interfaces
# PAN-OS NAT policy handles DNAT: 80 → Apache 10.1.0.4:80
resource "azurerm_lb_rule" "external_http" {
  name                           = "rule-http-inbound"
  loadbalancer_id                = azurerm_lb.external.id
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = 80
  frontend_ip_configuration_name = "fe-external-lb"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.external.id]
  probe_id                       = azurerm_lb_probe.external.id
  enable_floating_ip             = false
  idle_timeout_in_minutes        = 4
  load_distribution              = "Default"
  disable_outbound_snat          = true
}

# HTTPS rule – forwards port 443 to VM-Series untrust interfaces
# PAN-OS NAT policy handles DNAT: 443 → Apache 10.1.0.4:443 (or SSL offload)
resource "azurerm_lb_rule" "external_https" {
  name                           = "rule-https-inbound"
  loadbalancer_id                = azurerm_lb.external.id
  protocol                       = "Tcp"
  frontend_port                  = 443
  backend_port                   = 443
  frontend_ip_configuration_name = "fe-external-lb"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.external.id]
  probe_id                       = azurerm_lb_probe.external.id
  enable_floating_ip             = false
  idle_timeout_in_minutes        = 4
  load_distribution              = "Default"
  disable_outbound_snat          = true
}

# Outbound rule - SNAT for internet egress from VM-Series untrust interfaces
# protocol=All is allowed on outbound rules (only inbound HA Ports is restricted)
resource "azurerm_lb_outbound_rule" "external" {
  name                     = "outbound-fw-internet"
  loadbalancer_id          = azurerm_lb.external.id
  protocol                 = "All"
  backend_address_pool_id  = azurerm_lb_backend_address_pool.external.id
  allocated_outbound_ports = 1024

  frontend_ip_configuration {
    name = "fe-external-lb"
  }
}

###############################################################################
# Internal Load Balancer
###############################################################################

resource "azurerm_lb" "internal" {
  name                = "lb-internal-panos"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "Standard"
  tags                = var.tags

  frontend_ip_configuration {
    name                          = "fe-internal-lb"
    subnet_id                     = var.trust_subnet_id
    private_ip_address            = var.internal_lb_private_ip
    private_ip_address_allocation = "Static"
  }
}

resource "azurerm_lb_backend_address_pool" "internal" {
  name            = "bep-internal-panos"
  loadbalancer_id = azurerm_lb.internal.id
}

# Health probe for internal LB - same mechanism as external
resource "azurerm_lb_probe" "internal" {
  name                = "probe-fw-ssh"
  loadbalancer_id     = azurerm_lb.internal.id
  protocol            = "Tcp"
  port                = var.health_probe_port
  interval_in_seconds = 5
  number_of_probes    = 2
}

# HA Ports rule - required for next-hop LB / virtual appliance pattern
# Allows all traffic from any spoke to pass through the firewall
# This is what enables east-west and outbound traffic inspection
# NOTE: HA Ports (protocol=All) IS allowed on internal LBs (not on public LBs)
resource "azurerm_lb_rule" "internal_ha_ports" {
  name                           = "rule-ha-ports-all-traffic"
  loadbalancer_id                = azurerm_lb.internal.id
  protocol                       = "All"
  frontend_port                  = 0
  backend_port                   = 0
  frontend_ip_configuration_name = "fe-internal-lb"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.internal.id]
  probe_id                       = azurerm_lb_probe.internal.id
  enable_floating_ip             = false
  idle_timeout_in_minutes        = 4
  load_distribution              = "Default"
}
