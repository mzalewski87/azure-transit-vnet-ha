###############################################################################
# optional/aks-deploy/ — Provider Configuration
#
# Four providers, with the Bastion-tunnel pattern from phase2-panorama-config
# for panos and an exec-based AAD-free kubeconfig pattern for kubernetes+helm.
#
# Before running `terraform apply` you MUST have an active Bastion tunnel
# to Panorama on port 44300 — same setup as Phase 2a:
#
#   PANORAMA_ID=$(cd ../.. && terraform output -raw panorama_vm_id)
#   az network bastion tunnel \
#     --name bastion-management \
#     --resource-group rg-transit-hub \
#     --target-resource-id "$PANORAMA_ID" \
#     --resource-port 443 \
#     --port 44300
#
# Without the tunnel the panos provider keygen fails with "connection refused"
# on the first apply step (Phase C in main.tf).
###############################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
    panos = {
      source  = "PaloAltoNetworks/panos"
      version = "~> 1.11"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.hub_subscription_id
}

# Panorama via Bastion tunnel (127.0.0.1:44300). Timeout 180s matches phase2
# so concurrent Panorama commits don't time out the panos client.
provider "panos" {
  hostname = var.panorama_hostname
  port     = var.panorama_port
  username = var.panorama_username
  password = var.panorama_password
  timeout  = 180
}

# kubernetes + helm providers consume the AKS cluster's kube_config attributes.
# Avoiding kube_config_raw — discrete fields are preferred per terraform-docs
# best practices (avoids a temp kubeconfig file and is what AKS provider doc
# recommends).
#
# These depend on the AKS cluster being CREATED before the provider initialises
# — terraform handles this by deferring provider init until first use of a
# resource that consumes the provider. helm_release.* in modules/wordpress has
# depends_on=[module.aks_cluster] so the flow is correct.
provider "kubernetes" {
  host                   = module.aks_cluster.kube_config_host
  client_certificate     = base64decode(module.aks_cluster.kube_config_client_certificate)
  client_key             = base64decode(module.aks_cluster.kube_config_client_key)
  cluster_ca_certificate = base64decode(module.aks_cluster.kube_config_cluster_ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = module.aks_cluster.kube_config_host
    client_certificate     = base64decode(module.aks_cluster.kube_config_client_certificate)
    client_key             = base64decode(module.aks_cluster.kube_config_client_key)
    cluster_ca_certificate = base64decode(module.aks_cluster.kube_config_cluster_ca_certificate)
  }
}
