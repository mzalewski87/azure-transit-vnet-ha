###############################################################################
# WordPress Module
#
# Installs two Helm releases inside the AKS cluster:
#   1. ingress-nginx — LoadBalancer service annotated to provision an INTERNAL
#      Azure LB in snet-aks-ilb at a fixed IP (matches Panorama DNAT target).
#   2. bitnami/wordpress — WordPress + MariaDB (via the chart's MariaDB
#      sub-chart) with Azure Disk PVCs. Exposed via an Ingress that the
#      ingress-nginx controller picks up.
#
# Why pin chart versions:
#   helm_release re-evaluates the chart on every apply. Unpinned versions
#   would silently upgrade between applies, which is exactly the kind of
#   "why did this break?" scenario we want to avoid in a demo environment.
#
# helm + kubernetes providers consume kube_config from the aks_cluster module's
# outputs — see optional/aks-deploy/providers.tf for the wiring.
###############################################################################

terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
  }
}

###############################################################################
# Namespaces — explicit resources so destroy is clean (helm doesn't always
# clean up namespaces it created via `create_namespace`)
###############################################################################

resource "kubernetes_namespace" "ingress" {
  metadata {
    name = "ingress-nginx"
  }
}

resource "kubernetes_namespace" "wordpress" {
  metadata {
    name = "wordpress"
  }
}

###############################################################################
# ingress-nginx — internal LoadBalancer
#
# loadBalancerIP + the azure-load-balancer-internal annotations make AKS
# provision a Standard Internal LB in snet-aks-ilb with a static frontend
# matching the Panorama DNAT target IP (var.ingress_internal_lb_ip).
###############################################################################

resource "helm_release" "ingress_nginx" {
  name       = "ingress-nginx"
  namespace  = kubernetes_namespace.ingress.metadata[0].name
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  version    = var.ingress_nginx_chart_version

  # Use `set` blocks rather than a values file so the values are obviously
  # declarative + diffable in the terraform plan output.
  set {
    name  = "controller.service.type"
    value = "LoadBalancer"
  }
  set {
    name  = "controller.service.loadBalancerIP"
    value = var.ingress_internal_lb_ip
  }
  set {
    name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/azure-load-balancer-internal"
    value = "true"
    type  = "string"
  }
  set {
    name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/azure-load-balancer-internal-subnet"
    value = var.ingress_subnet_name
    type  = "string"
  }
  # Modest resource requests — controller is mostly idle for a demo workload.
  set {
    name  = "controller.resources.requests.cpu"
    value = "50m"
  }
  set {
    name  = "controller.resources.requests.memory"
    value = "90Mi"
  }
  # Disable admission webhook validation timeout from being too aggressive —
  # AKS scheduler may delay scheduling on first deploy.
  set {
    name  = "controller.admissionWebhooks.timeoutSeconds"
    value = "29"
  }

  # The chart waits for the controller pods + service to be Ready. Combined
  # with the LB provisioning (~2-3 min on first AKS deploy), this can take
  # ~5 min.
  wait    = true
  timeout = 600
}

###############################################################################
# WordPress (Bitnami) — chart bundles MariaDB sub-chart with PVCs.
#
# ingress.enabled + ingress.hostname=* makes the chart create an Ingress
# resource that matches any Host header. ingress-nginx routes traffic to
# the WordPress ClusterIP service.
###############################################################################

resource "helm_release" "wordpress" {
  name       = "wordpress"
  namespace  = kubernetes_namespace.wordpress.metadata[0].name
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "wordpress"
  version    = var.wordpress_chart_version

  set {
    name  = "wordpressUsername"
    value = var.wp_admin_username
  }
  set_sensitive {
    name  = "wordpressPassword"
    value = var.wp_admin_password
  }
  set {
    name  = "wordpressBlogName"
    value = var.wp_blog_name
  }
  # Ingress configuration — controller is ingress-nginx, no TLS at this layer
  # because AFD terminates TLS at the edge.
  set {
    name  = "ingress.enabled"
    value = "true"
  }
  set {
    name  = "ingress.ingressClassName"
    value = "nginx"
  }
  set {
    name  = "ingress.hostname"
    value = "*"
    type  = "string"
  }
  set {
    name  = "ingress.tls"
    value = "false"
  }
  # Service is ClusterIP — exposed only through Ingress.
  set {
    name  = "service.type"
    value = "ClusterIP"
  }
  # WordPress content PVC (themes/plugins/uploads).
  set {
    name  = "persistence.enabled"
    value = "true"
  }
  set {
    name  = "persistence.storageClass"
    value = "managed-csi"
  }
  set {
    name  = "persistence.size"
    value = "10Gi"
  }
  # MariaDB sub-chart configuration.
  set {
    name  = "mariadb.enabled"
    value = "true"
  }
  set {
    name  = "mariadb.architecture"
    value = "standalone"
  }
  set {
    name  = "mariadb.primary.persistence.enabled"
    value = "true"
  }
  set {
    name  = "mariadb.primary.persistence.storageClass"
    value = "managed-csi"
  }
  set {
    name  = "mariadb.primary.persistence.size"
    value = "8Gi"
  }
  # Disable resource auto-tuning that defaults to high values; demo nodes
  # have only 2 vCPUs.
  set {
    name  = "resourcesPreset"
    value = "small"
  }
  set {
    name  = "mariadb.primary.resourcesPreset"
    value = "small"
  }

  # Wait for the chart to settle — image pulls go through FW (we just
  # configured the EDL!) so first deploy can be slow if MCR ratelimits.
  wait    = true
  timeout = 900

  depends_on = [helm_release.ingress_nginx]
}
