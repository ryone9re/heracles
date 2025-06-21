# OCI Infrastructure Resources
# VCN, Subnets, OKE Cluster, and Node Pool configuration

# Data sources for availability domains and regions
data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_ocid
}

data "oci_identity_regions" "current" {}

# VCN (Virtual Cloud Network)
resource "oci_core_vcn" "heracles_vcn" {
  compartment_id = var.compartment_ocid
  display_name   = "heracles-vcn"
  cidr_block     = "10.0.0.0/16"
  dns_label      = "heraclesvcn"

  freeform_tags = {
    "Project" = "heracles"
    "Environment" = "prod"
  }
}

# Internet Gateway
resource "oci_core_internet_gateway" "heracles_igw" {
  compartment_id = var.compartment_ocid
  display_name   = "heracles-igw"
  vcn_id         = oci_core_vcn.heracles_vcn.id
  enabled        = true

  freeform_tags = {
    "Project" = "heracles"
    "Environment" = "prod"
  }
}

# Default Route Table update
resource "oci_core_default_route_table" "heracles_default_route_table" {
  manage_default_resource_id = oci_core_vcn.heracles_vcn.default_route_table_id
  display_name               = "heracles-default-route-table"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.heracles_igw.id
  }

  freeform_tags = {
    "Project" = "heracles"
    "Environment" = "prod"
  }
}

# Security List for OKE
resource "oci_core_security_list" "heracles_oke_security_list" {
  compartment_id = var.compartment_ocid
  display_name   = "heracles-oke-security-list"
  vcn_id         = oci_core_vcn.heracles_vcn.id

  # Ingress rules
  ingress_security_rules {
    protocol  = "6" # TCP
    source    = "0.0.0.0/0"
    stateless = false

    tcp_options {
      min = 6443
      max = 6443
    }
  }

  ingress_security_rules {
    protocol  = "all"
    source    = "10.0.0.0/16"
    stateless = false
  }

  # Egress rules
  egress_security_rules {
    protocol         = "all"
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    stateless        = false
  }

  freeform_tags = {
    "Project" = "heracles"
    "Environment" = "prod"
  }
}

# Worker Node Subnet
resource "oci_core_subnet" "heracles_worker_subnet" {
  compartment_id    = var.compartment_ocid
  display_name      = "heracles-worker-subnet"
  vcn_id            = oci_core_vcn.heracles_vcn.id
  cidr_block        = "10.0.1.0/24"
  dns_label         = "workers"
  security_list_ids = [oci_core_security_list.heracles_oke_security_list.id]
  route_table_id    = oci_core_vcn.heracles_vcn.default_route_table_id

  freeform_tags = {
    "Project" = "heracles"
    "Environment" = "prod"
    "Type" = "worker"
  }
}

# Load Balancer Subnet
resource "oci_core_subnet" "heracles_lb_subnet" {
  compartment_id    = var.compartment_ocid
  display_name      = "heracles-lb-subnet"
  vcn_id            = oci_core_vcn.heracles_vcn.id
  cidr_block        = "10.0.2.0/24"
  dns_label         = "loadbalancers"
  security_list_ids = [oci_core_security_list.heracles_oke_security_list.id]
  route_table_id    = oci_core_vcn.heracles_vcn.default_route_table_id

  freeform_tags = {
    "Project" = "heracles"
    "Environment" = "prod"
    "Type" = "lb"
  }
}

# API Server Subnet
resource "oci_core_subnet" "heracles_api_subnet" {
  compartment_id    = var.compartment_ocid
  display_name      = "heracles-api-subnet"
  vcn_id            = oci_core_vcn.heracles_vcn.id
  cidr_block        = "10.0.3.0/24"
  dns_label         = "apiserver"
  security_list_ids = [oci_core_security_list.heracles_oke_security_list.id]
  route_table_id    = oci_core_vcn.heracles_vcn.default_route_table_id

  freeform_tags = {
    "Project" = "heracles"
    "Environment" = "prod"
    "Type" = "api"
  }
}

# OKE Cluster
resource "oci_containerengine_cluster" "heracles_oke_cluster" {
  compartment_id     = var.compartment_ocid
  kubernetes_version = var.kubernetes_version
  name               = var.cluster_name
  vcn_id             = oci_core_vcn.heracles_vcn.id

  cluster_pod_network_options {
    cni_type = "FLANNEL_OVERLAY"
  }

  endpoint_config {
    is_public_ip_enabled = true
    subnet_id            = oci_core_subnet.heracles_api_subnet.id
  }

  options {
    service_lb_subnet_ids = [oci_core_subnet.heracles_lb_subnet.id]
    
    add_ons {
      is_kubernetes_dashboard_enabled = false
      is_tiller_enabled              = false
    }

    admission_controller_options {
      is_pod_security_policy_enabled = false
    }

    kubernetes_network_config {
      pods_cidr     = "10.244.0.0/16"
      services_cidr = "10.96.0.0/16"
    }
  }

  freeform_tags = {
    "Project" = "heracles"
    "Environment" = "prod"
  }
}

# Node Pool
resource "oci_containerengine_node_pool" "heracles_node_pool" {
  cluster_id         = oci_containerengine_cluster.heracles_oke_cluster.id
  compartment_id     = var.compartment_ocid
  kubernetes_version = var.kubernetes_version
  name               = var.node_pool_name
  
  node_config_details {
    placement_configs {
      availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
      subnet_id           = oci_core_subnet.heracles_worker_subnet.id
    }
    
    size = var.node_count
  }

  node_shape = var.node_shape

  node_shape_config {
    memory_in_gbs = var.node_memory_gb
    ocpus         = var.node_ocpus
  }

  node_source_details {
    image_id    = var.node_image_id
    source_type = "IMAGE"
  }

  initial_node_labels {
    key   = "node-type"
    value = "worker"
  }

  freeform_tags = {
    "Project" = "heracles"
    "Environment" = "prod"
  }
}
