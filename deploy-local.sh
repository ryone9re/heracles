#!/bin/bash

# Heracles Local Deployment Verification Script
# ローカル環境でのKubernetes構成検証用スクリプト

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Wait for resources to be ready
wait_for_deployment() {
    local namespace=$1
    local deployment=$2
    local timeout=${3:-300}
    
    log_info "Waiting for deployment $deployment in namespace $namespace to be ready..."
    if kubectl wait --for=condition=available --timeout=${timeout}s deployment/$deployment -n $namespace 2>/dev/null; then
        log_success "Deployment $deployment is ready"
        return 0
    else
        log_error "Deployment $deployment failed to become ready within ${timeout}s"
        return 1
    fi
}

# Wait for CRDs to be established
wait_for_crd() {
    local crd_name=$1
    local timeout=${2:-120}
    
    log_info "Waiting for CRD $crd_name to be established..."
    if kubectl wait --for=condition=established --timeout=${timeout}s crd/$crd_name 2>/dev/null; then
        log_success "CRD $crd_name is established"
        return 0
    else
        log_error "CRD $crd_name failed to be established within ${timeout}s"
        return 1
    fi
}

# Check if Helm is available
check_helm() {
    if ! command -v helm &> /dev/null; then
        log_error "Helm is not installed or not in PATH"
        return 1
    fi
    log_success "Helm is available"
}

# Add Helm repositories
add_helm_repos() {
    log_info "Adding required Helm repositories..."
    
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx || true
    helm repo add jetstack https://charts.jetstack.io || true
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
    helm repo add grafana https://grafana.github.io/helm-charts || true
    helm repo add bitnami https://charts.bitnami.com/bitnami || true
    
    helm repo update
    log_success "Helm repositories updated"
}

# Deploy Layer 1: Core Infrastructure
deploy_layer1() {
    log_info "=== Deploying Layer 1: Core Infrastructure ==="
    
    # Deploy Ingress NGINX (simplified for local)
    log_info "Deploying Ingress NGINX..."
    helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace ingress-nginx \
        --create-namespace \
        --set controller.service.type=NodePort \
        --set controller.admissionWebhooks.enabled=false \
        --set controller.replicaCount=1 \
        --set controller.resources.requests.cpu=50m \
        --set controller.resources.requests.memory=64Mi \
        --wait
    
    # Deploy cert-manager
    log_info "Deploying cert-manager..."
    helm upgrade --install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --create-namespace \
        --set installCRDs=true \
        --set resources.requests.cpu=10m \
        --set resources.requests.memory=32Mi \
        --set webhook.resources.requests.cpu=10m \
        --set webhook.resources.requests.memory=32Mi \
        --set cainjector.resources.requests.cpu=10m \
        --set cainjector.resources.requests.memory=32Mi \
        --wait
        
    log_success "Layer 1 deployment completed"
}

# Deploy Layer 2: Storage & Database (simplified)
deploy_layer2() {
    log_info "=== Deploying Layer 2: Storage & Database (Simplified) ==="
    
    # Deploy PostgreSQL (single instance for testing)
    log_info "Deploying PostgreSQL..."
    helm upgrade --install postgresql bitnami/postgresql \
        --namespace database \
        --create-namespace \
        --set auth.postgresPassword=testpassword \
        --set primary.resources.requests.memory=128Mi \
        --set primary.resources.requests.cpu=50m \
        --set primary.persistence.size=1Gi \
        --wait
    
    # Deploy Redis (single instance for testing)
    log_info "Deploying Redis..."
    helm upgrade --install redis bitnami/redis \
        --namespace database \
        --set auth.password=testpassword \
        --set master.resources.requests.memory=64Mi \
        --set master.resources.requests.cpu=50m \
        --set master.persistence.size=1Gi \
        --set replica.replicaCount=0 \
        --wait
        
    log_success "Layer 2 deployment completed"
}

# Deploy Layer 3: Monitoring (simplified)
deploy_layer3() {
    log_info "=== Deploying Layer 3: Monitoring (Simplified) ==="
    
    # Deploy Prometheus (minimal setup)
    log_info "Deploying Prometheus..."
    helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
        --namespace monitoring \
        --create-namespace \
        --set prometheus.prometheusSpec.resources.requests.memory=256Mi \
        --set prometheus.prometheusSpec.resources.requests.cpu=100m \
        --set prometheus.prometheusSpec.retention=1d \
        --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=2Gi \
        --set grafana.resources.requests.memory=64Mi \
        --set grafana.resources.requests.cpu=50m \
        --set grafana.persistence.enabled=true \
        --set grafana.persistence.size=1Gi \
        --set alertmanager.alertmanagerSpec.resources.requests.memory=64Mi \
        --set alertmanager.alertmanagerSpec.resources.requests.cpu=50m \
        --wait
        
    log_success "Layer 3 deployment completed"
}

# Verification function
verify_deployments() {
    log_info "=== Verifying Deployments ==="
    
    # Check all pods
    kubectl get pods --all-namespaces
    
    # Check services
    kubectl get services --all-namespaces
    
    # Check ingress
    kubectl get ingress --all-namespaces
    
    log_success "Verification completed"
}

# Main deployment function
main() {
    log_info "Starting Heracles local deployment verification..."
    
    # Pre-flight checks
    if ! kubectl cluster-info &>/dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi
    
    check_helm
    add_helm_repos
    
    # Deploy in layers
    deploy_layer1
    deploy_layer2
    deploy_layer3
    
    # Verify
    verify_deployments
    
    log_success "Heracles local deployment verification completed!"
    log_info "Access Grafana: kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80"
    log_info "Grafana credentials: admin / $(kubectl get secret -n monitoring prometheus-grafana -o jsonpath='{.data.admin-password}' | base64 -d)"
}

# Cleanup function
cleanup() {
    log_info "Cleaning up deployments..."
    
    helm uninstall prometheus -n monitoring || true
    helm uninstall redis -n database || true
    helm uninstall postgresql -n database || true
    helm uninstall cert-manager -n cert-manager || true
    helm uninstall ingress-nginx -n ingress-nginx || true
    
    kubectl delete namespace monitoring database cert-manager ingress-nginx || true
    
    log_success "Cleanup completed"
}

# Handle script arguments
case "${1:-deploy}" in
    deploy)
        main
        ;;
    cleanup)
        cleanup
        ;;
    verify)
        verify_deployments
        ;;
    *)
        echo "Usage: $0 {deploy|cleanup|verify}"
        exit 1
        ;;
esac