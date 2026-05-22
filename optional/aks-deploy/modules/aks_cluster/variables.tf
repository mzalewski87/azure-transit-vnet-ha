###############################################################################
# AKS Cluster Module – Variables
###############################################################################

variable "location" {
  description = "Azure region for the AKS cluster"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group for the AKS cluster (passed from aks_network module)"
  type        = string
}

variable "aks_nodes_subnet_id" {
  description = "Subnet ID for AKS node pool (snet-aks-nodes in spoke3)"
  type        = string
}

variable "cluster_name" {
  description = "AKS cluster name"
  type        = string
  default     = "aks-spoke3-wordpress"
}

variable "kubernetes_version" {
  description = "Kubernetes version (omit to let AKS pick the default supported version)"
  type        = string
  default     = null
}

variable "node_count" {
  description = "Number of nodes in the default node pool"
  type        = number
  default     = 2
}

variable "node_vm_size" {
  description = "VM size for AKS nodes"
  type        = string
  default     = "Standard_D2s_v3"
}

variable "pod_cidr" {
  description = "CIDR for AKS overlay pods (NOT in VNet — Azure CNI Overlay does NAT pod→node at egress)"
  type        = string
  default     = "10.244.0.0/16"
}

variable "service_cidr" {
  description = "CIDR for Kubernetes Services (must not overlap with VNet or pod_cidr)"
  type        = string
  default     = "10.0.0.0/16"
}

variable "dns_service_ip" {
  description = "Cluster DNS service IP — must be inside service_cidr"
  type        = string
  default     = "10.0.0.10"
}

variable "tags" {
  description = "Tags applied to AKS + UAI"
  type        = map(string)
  default     = {}
}
