# Outputs for OCI Infrastructure

output "vcn_id" {
  description = "OCID of the VCN"
  value       = oci_core_vcn.heracles_vcn.id
}

output "worker_subnet_id" {
  description = "OCID of the worker subnet"
  value       = oci_core_subnet.heracles_worker_subnet.id
}

output "lb_subnet_id" {
  description = "OCID of the load balancer subnet"
  value       = oci_core_subnet.heracles_lb_subnet.id
}

output "api_subnet_id" {
  description = "OCID of the API server subnet"  
  value       = oci_core_subnet.heracles_api_subnet.id
}

output "cluster_id" {
  description = "OCID of the OKE cluster"
  value       = oci_containerengine_cluster.heracles_oke_cluster.id
}

output "node_pool_id" {
  description = "OCID of the node pool"
  value       = oci_containerengine_node_pool.heracles_node_pool.id
}

output "cluster_endpoint" {
  description = "Kubernetes API server endpoint"
  value       = oci_containerengine_cluster.heracles_oke_cluster.endpoints[0].kubernetes
}

output "kubeconfig_command" {
  description = "Command to generate kubeconfig"
  value       = "oci ce cluster create-kubeconfig --cluster-id ${oci_containerengine_cluster.heracles_oke_cluster.id} --file ~/.kube/config --region ${var.region} --token-version 2.0.0"
}

# ArgoCD outputs (existing)
output "argocd_namespace" {
  value = kubernetes_namespace.argocd.metadata[0].name
}

output "cluster_name" {
  value = local.cluster_name
}
