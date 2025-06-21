# Variables for OCI Infrastructure

variable "compartment_ocid" {
  description = "The OCID of the compartment where resources will be created"
  type        = string
}

variable "tenancy_ocid" {
  description = "The OCID of the tenancy"
  type        = string
}

variable "user_ocid" {
  description = "The OCID of the user"
  type        = string
}

variable "fingerprint" {
  description = "The fingerprint of the key pair"
  type        = string
}

variable "private_key_path" {
  description = "The path to the private key file"
  type        = string
}

variable "region" {
  description = "The OCI region"
  type        = string
  default     = "ap-tokyo-1"
}

# Kubernetes cluster configuration
variable "cluster_name" {
  description = "Name of the OKE cluster"
  type        = string
  default     = "heracles-oke-cluster"
}

variable "kubernetes_version" {
  description = "Kubernetes version for the cluster"
  type        = string
  default     = "v1.28.2"
}

variable "node_pool_name" {
  description = "Name of the node pool"
  type        = string
  default     = "heracles-node-pool"
}

variable "node_shape" {
  description = "Shape of the worker nodes (Always Free: VM.Standard.A1.Flex)"
  type        = string
  default     = "VM.Standard.A1.Flex"
}

variable "node_count" {
  description = "Number of worker nodes (Always Free: up to 4 total OCPUs)"
  type        = number
  default     = 4
}

variable "node_ocpus" {
  description = "Number of OCPUs per node"
  type        = number
  default     = 1
}

variable "node_memory_gb" {
  description = "Memory in GB per node"
  type        = number
  default     = 6
}

variable "node_image_id" {
  description = "OCID of the node image"
  type        = string
  default     = "ocid1.image.oc1.ap-tokyo-1.aaaaaaaaydrjlx7hqbpzpvfob3gavnbfhmptsagw3m7xzlxj4jg5xdpfnnwa" # Oracle Linux 8.8 aarch64 2023.10.24-0
}

# Object Storage configuration for Terraform state
variable "object_storage_namespace" {
  description = "Object Storage namespace for Terraform state"
  type        = string
}
