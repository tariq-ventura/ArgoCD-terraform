provider "helm" {
  kubernetes {
    host                   = "https://${google_container_cluster.primary.endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(google_container_cluster.primary.master_auth.0.cluster_ca_certificate)
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  namespace  = "argocd"

  depends_on = [
    google_container_cluster.primary
  ]
}

resource "helm_release" "ingress_nginx" {
  name       = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  namespace  = "ingress-nginx"

  depends_on = [
    google_container_cluster.primary
  ]
}

resource "helm_release" "cert_manager" {
  name      = "cert-manager"
  chart     = "./cert-manager/cert-manager-v1.13.2.tgz"
  namespace = "cert-manager"
  version   = "v1.12.3"
  set {
    name  = "installCRDs"
    value = "true"
  }
  depends_on = [
    google_container_cluster.primary
  ]
}