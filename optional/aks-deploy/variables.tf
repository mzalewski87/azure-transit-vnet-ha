###############################################################################
# optional/aks-deploy/ — Root Variables
###############################################################################

#------------------------------------------------------------------------------
# Azure subscriptions / region / RGs (root-level inputs)
#------------------------------------------------------------------------------

variable "hub_subscription_id" {
  description = "Azure subscription ID for hub (matches hub_subscription_id in root terraform.tfvars)"
  type        = string
}

variable "location" {
  description = "Azure region — must match the location of the existing Transit Hub VNet"
  type        = string
  default     = "germanywestcentral"
}

variable "transit_resource_group_name" {
  description = "Existing Transit Hub resource group (matches hub_resource_group_name in root tfvars)"
  type        = string
  default     = "rg-transit-hub"
}

variable "management_resource_group_name" {
  description = "Resource group hosting the management VNet (Panorama + Bastion) — typically the same as transit RG"
  type        = string
  default     = "rg-transit-hub"
}

variable "management_vnet_name" {
  description = "Existing Management VNet name where snet-edl will be added (default vnet-management)"
  type        = string
  default     = "vnet-management"
}

variable "transit_vnet_name" {
  description = "Existing Transit Hub VNet name (for peering with spoke3)"
  type        = string
  default     = "vnet-transit-hub"
}

variable "fw_mgmt_subnet_cidr" {
  description = "CIDR of FW MGMT subnet in transit VNet (only source allowed to pull EDLs)"
  type        = string
  default     = "10.110.255.0/24"
}

#------------------------------------------------------------------------------
# Spoke3 / AKS network
#------------------------------------------------------------------------------

variable "aks_resource_group_name" {
  description = "Resource group for the AKS spoke3 + cluster"
  type        = string
  default     = "rg-app3-aks"
}

variable "spoke3_vnet_address_space" {
  description = "Spoke3 VNet CIDR"
  type        = string
  default     = "10.114.0.0/16"
}

variable "aks_nodes_subnet_cidr" {
  description = "Subnet for AKS node pool"
  type        = string
  default     = "10.114.0.0/24"
}

variable "aks_ilb_subnet_cidr" {
  description = "Subnet for AKS internal LB (ingress)"
  type        = string
  default     = "10.114.1.0/27"
}

variable "internal_lb_private_ip" {
  description = "Private IP of the existing transit Internal LB (UDR next-hop)"
  type        = string
  default     = "10.110.0.21"
}

#------------------------------------------------------------------------------
# EDL server
#------------------------------------------------------------------------------

variable "edl_subnet_cidr" {
  description = "CIDR for snet-edl in management VNet"
  type        = string
  default     = "10.255.2.0/27"
}

variable "edl_private_ip" {
  description = "Static private IP of the EDL nginx server (must be inside edl_subnet_cidr)"
  type        = string
  default     = "10.255.2.4"
}

variable "edl_admin_username" {
  description = "SSH admin username for the EDL VM"
  type        = string
  default     = "edladmin"
}

variable "edl_admin_password" {
  description = "SSH admin password for the EDL VM (sensitive). Reuse admin_password from root tfvars if you don't want a separate credential."
  type        = string
  sensitive   = true
}

variable "edl_vm_size" {
  description = "VM size for the EDL server (B1ms is restricted on newer subscriptions; B2s_v2 is the safe default)"
  type        = string
  default     = "Standard_B2s_v2"
}

#------------------------------------------------------------------------------
# Panorama (Bastion tunnel)
#------------------------------------------------------------------------------

variable "panorama_hostname" {
  description = "Panorama hostname — 127.0.0.1 when using Bastion tunnel"
  type        = string
  default     = "127.0.0.1"
}

variable "panorama_port" {
  description = "Panorama HTTPS port via Bastion tunnel"
  type        = number
  default     = 44300
}

variable "panorama_username" {
  description = "Panorama admin username"
  type        = string
  default     = "panadmin"
}

variable "panorama_password" {
  description = "Panorama admin password (sensitive — same as admin_password in root tfvars)"
  type        = string
  sensitive   = true
}

variable "panorama_device_group" {
  description = "Existing Panorama Device Group name (Phase 2a output)"
  type        = string
  default     = "Transit-VNet-DG"
}

variable "panorama_template" {
  description = "Existing Panorama Template name (Phase 2a output)"
  type        = string
  default     = "Transit-VNet-Template"
}

#------------------------------------------------------------------------------
# External LB / Front Door (existing infra references)
#------------------------------------------------------------------------------

variable "external_lb_name" {
  description = "Existing External LB name"
  type        = string
  default     = "lb-external-panos"
}

variable "external_lb_public_ip" {
  description = "Public IP of the existing External LB (look up via `terraform output -raw external_lb_public_ip_address` in root)"
  type        = string
}

variable "frontdoor_profile_name" {
  description = "Existing AFD profile name"
  type        = string
  default     = "afd-panos-transit"
}

#------------------------------------------------------------------------------
# AKS cluster sizing
#------------------------------------------------------------------------------

variable "aks_cluster_name" {
  description = "AKS cluster name"
  type        = string
  default     = "aks-spoke3-wordpress"
}

variable "aks_node_count" {
  description = "Number of AKS nodes"
  type        = number
  default     = 2
}

variable "aks_node_vm_size" {
  description = "VM size for AKS nodes (D2s_v3 is not offered on newer subscriptions; D2s_v5 is the safe default)"
  type        = string
  default     = "Standard_D2s_v5"
}

variable "aks_kubernetes_version" {
  description = "Kubernetes version (omit → latest stable supported by AKS)"
  type        = string
  default     = null
}

variable "aks_region" {
  description = "AKS region for the *.hcp.<region>.azmk8s.io FQDN + AzureCloud.<region> service-tag lookup"
  type        = string
  default     = "germanywestcentral"
}

variable "aks_ingress_internal_lb_ip" {
  description = "Static IP for AKS internal LB (DNAT target on FW). MUST be inside aks_ilb_subnet_cidr (snet-aks-ilb) because that's where Azure provisions the LB frontend per the ingress-nginx annotation."
  type        = string
  default     = "10.114.1.4"
}

#------------------------------------------------------------------------------
# WordPress
#------------------------------------------------------------------------------

variable "wp_admin_username" {
  description = "WordPress admin username"
  type        = string
  default     = "wpadmin"
}

variable "wp_admin_password" {
  description = "WordPress admin password (sensitive)"
  type        = string
  sensitive   = true
}

variable "wp_blog_name" {
  description = "WordPress blog title"
  type        = string
  default     = "PANW Demo – AKS WordPress"
}

#------------------------------------------------------------------------------
# Tags
#------------------------------------------------------------------------------

variable "tags" {
  description = "Tags applied to all created resources"
  type        = map(string)
  default = {
    Environment = "Demo"
    Project     = "PAN-Transit-VNet-HA"
    ManagedBy   = "Terraform"
    Module      = "optional/aks-deploy"
  }
}
