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
  # Bitnami deprecated free versioned tags on `docker.io/bitnami/*` in
  # 2025-08; legacy tags moved to `docker.io/bitnamilegacy/*`. The pinned
  # chart 23.0.0 still references `bitnami/wordpress:6.5.5-debian-12-r7`
  # and `bitnami/mariadb:11.4.2-debian-12-r0` which now 404 on pull. Repo
  # overrides keep the same tags but point at the still-public legacy org.
  set {
    name  = "image.repository"
    value = "bitnamilegacy/wordpress"
  }
  set {
    name  = "mariadb.image.repository"
    value = "bitnamilegacy/mariadb"
  }
  # Disable the chart's built-in Ingress. The Bitnami chart requires a single
  # valid DNS hostname in `ingress.hostname`; bare `*` is invalid in K8s
  # Ingress spec (`spec.rules[].host` must be exact or `*.<dns-suffix>`).
  # We create a host-less Ingress ourselves below (default_backend = catch-all)
  # so AFD can forward any Host header (currently the External LB public IP)
  # without coupling chart values to a specific hostname.
  set {
    name  = "ingress.enabled"
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

###############################################################################
# Catch-all Ingress for WordPress.
#
# Replaces the chart's built-in Ingress (disabled above). Uses default_backend
# with no rules so any Host header (including bare-IP from AFD) routes to the
# `wordpress` ClusterIP service that the Bitnami chart creates on port 80.
###############################################################################
resource "kubernetes_ingress_v1" "wordpress" {
  metadata {
    name      = "wordpress"
    namespace = kubernetes_namespace.wordpress.metadata[0].name
  }

  spec {
    ingress_class_name = "nginx"

    default_backend {
      service {
        name = "wordpress"
        port {
          number = 80
        }
      }
    }
  }

  depends_on = [helm_release.wordpress]
}
