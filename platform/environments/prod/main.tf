terraform {
  required_version = ">= 1.0"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.11"
    }
  }
}

locals {
  cluster_name = "heracles-prod"
  namespace    = "argocd"
}

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = local.namespace
    labels = {
      "app.kubernetes.io/name"      = "argocd"
      "app.kubernetes.io/component" = "server"
    }
  }
}

resource "kubernetes_namespace" "observability" {
  metadata {
    name = "observability"
    labels = {
      "app.kubernetes.io/name" = "observability-stack"
    }
  }
}

resource "kubernetes_namespace" "ingress-nginx" {
  metadata {
    name = "ingress-nginx"
    labels = {
      "app.kubernetes.io/name" = "ingress-nginx"
    }
  }
}

resource "kubernetes_namespace" "cert-manager" {
  metadata {
    name = "cert-manager"
    labels = {
      "app.kubernetes.io/name" = "cert-manager"
    }
  }
}

resource "kubernetes_namespace" "external-dns" {
  metadata {
    name = "external-dns"
    labels = {
      "app.kubernetes.io/name" = "external-dns"
    }
  }
}

resource "kubernetes_namespace" "vault" {
  metadata {
    name = "vault"
    labels = {
      "app.kubernetes.io/name" = "vault"
    }
  }
}

resource "kubernetes_namespace" "knative-serving" {
  metadata {
    name = "knative-serving"
    labels = {
      "app.kubernetes.io/name" = "knative-serving"
    }
  }
}

resource "kubernetes_namespace" "knative-eventing" {
  metadata {
    name = "knative-eventing"
    labels = {
      "app.kubernetes.io/name" = "knative-eventing"
    }
  }
}

resource "kubernetes_namespace" "harbor" {
  metadata {
    name = "harbor"
    labels = {
      "app.kubernetes.io/name" = "harbor"
    }
  }
}

resource "kubernetes_namespace" "postgres-operator" {
  metadata {
    name = "postgres-operator"
    labels = {
      "app.kubernetes.io/name" = "postgres-operator"
    }
  }
}

resource "kubernetes_namespace" "redis-operator" {
  metadata {
    name = "redis-operator"
    labels = {
      "app.kubernetes.io/name" = "redis-operator"
    }
  }
}

resource "kubernetes_namespace" "minio-operator" {
  metadata {
    name = "minio-operator"
    labels = {
      "app.kubernetes.io/name" = "minio-operator"
    }
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "5.46.8"
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  values = [
    yamlencode({
      global = {
        domain = "argocd.ryone.dev"
      }
      
      configs = {
        params = {
          "server.insecure" = true
        }
        cm = {
          "application.instanceLabelKey" = "argocd.argoproj.io/instance"
          "server.rbac.log.enforce.enable" = "true"
          url = "https://argocd.ryone.dev"
        }
        rbac = {
          "policy.default" = "role:readonly"
          "policy.csv" = <<-EOT
            p, role:admin, applications, *, */*, allow
            p, role:admin, clusters, *, *, allow
            p, role:admin, repositories, *, *, allow
            p, role:admin, certificates, *, *, allow
            p, role:admin, accounts, *, *, allow
            p, role:admin, gpgkeys, *, *, allow
            p, role:admin, logs, *, *, allow
            p, role:admin, exec, *, *, allow
            g, argocd-admin, role:admin
          EOT
        }
      }

      server = {
        ingress = {
          enabled = true
          ingressClassName = "nginx"
          hostname = "argocd.ryone.dev"
          annotations = {
            "cert-manager.io/cluster-issuer" = "letsencrypt-prod"
            "nginx.ingress.kubernetes.io/ssl-redirect" = "true"
            "nginx.ingress.kubernetes.io/backend-protocol" = "GRPC"
          }
          tls = true
        }
        extraArgs = [
          "--insecure"
        ]
      }

      controller = {
        metrics = {
          enabled = true
          serviceMonitor = {
            enabled = true
          }
        }
      }

      dex = {
        enabled = false
      }

      redis = {
        metrics = {
          enabled = true
          serviceMonitor = {
            enabled = true
          }
        }
      }

      repoServer = {
        metrics = {
          enabled = true
          serviceMonitor = {
            enabled = true
          }
        }
      }

      applicationSet = {
        enabled = true
        metrics = {
          enabled = true
          serviceMonitor = {
            enabled = true
          }
        }
      }
    })
  ]

  depends_on = [
    kubernetes_namespace.argocd
  ]
}

output "argocd_namespace" {
  value = kubernetes_namespace.argocd.metadata[0].name
}

output "cluster_name" {
  value = local.cluster_name
}