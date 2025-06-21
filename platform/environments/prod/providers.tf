# Provider Configuration

provider "oci" {
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
  region           = var.region
}

provider "kubernetes" {
  host                   = oci_containerengine_cluster.heracles_oke_cluster.endpoints[0].kubernetes
  cluster_ca_certificate = base64decode(oci_containerengine_cluster.heracles_oke_cluster.kubernetes_network_config[0].cluster_ca_certificate)
  
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "oci"
    args = [
      "ce", "cluster", "generate-token",
      "--cluster-id", oci_containerengine_cluster.heracles_oke_cluster.id,
      "--region", var.region
    ]
  }
}

provider "helm" {
  kubernetes {
    host                   = oci_containerengine_cluster.heracles_oke_cluster.endpoints[0].kubernetes
    cluster_ca_certificate = base64decode(oci_containerengine_cluster.heracles_oke_cluster.kubernetes_network_config[0].cluster_ca_certificate)
    
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "oci"
      args = [
        "ce", "cluster", "generate-token",
        "--cluster-id", oci_containerengine_cluster.heracles_oke_cluster.id,
        "--region", var.region
      ]
    }
  }
}
