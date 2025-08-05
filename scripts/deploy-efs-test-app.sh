#!/bin/bash

# Deploy EFS Test Applications to EKS Clusters
set -e

PROJECT_ROOT="."
source ./scripts/config.sh

# Source infrastructure environment files if they exist
if [ -f "${PROJECT_ROOT}/efs-infrastructure.env" ]; then
    source "${PROJECT_ROOT}/efs-infrastructure.env"
elif [ -f "${PROJECT_ROOT}/corebank-efs.env" ]; then
    source "${PROJECT_ROOT}/corebank-efs.env"
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
    exit 1
}

info() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $1${NC}"
}

# Substitute environment variables in Kubernetes manifest
substitute_variables() {
    local input_file=$1
    local output_file=$2
    
    # Create temporary file with substituted variables
    envsubst < "$input_file" > "$output_file"
}

# Deploy application to EKS cluster
deploy_application() {
    local account_id=$1
    local account_name=$2
    local manifest_file=$3
    
    log "Deploying EFS test application to $account_name cluster..."
    
    # Switch to account and set kubectl context
    export AWS_PROFILE="$account_name"
    kubectl config use-context "$account_name-cluster"
    
    # Verify cluster connectivity
    info "Verifying cluster connectivity"
    kubectl get nodes
    
    # Create namespace if it doesn't exist
    info "Creating namespace"
    kubectl apply -f - << EOF
apiVersion: v1
kind: Namespace
metadata:
  name: efs-test
  labels:
    name: efs-test
    purpose: efs-testing
EOF
    
    # Set environment variables for substitution
    export ECR_REGISTRY=""  # Empty since we include full image path
    export EFS_COREBANK_ID="$EFS_COREBANK_ID"
    export ACCOUNT_ID="$account_id"
    export ACCOUNT_NAME="$account_name"
    export AWS_REGION="$AWS_REGION"
    export COREBANK_REPLICAS="${COREBANK_REPLICAS:-2}"
    export WRITE_TIMEOUT="${WRITE_TIMEOUT:-30}"
    
    # Set account-specific variables
    if [ "$account_name" = "corebank" ]; then
        export IMAGE_URI="$COREBANK_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com/efs-test-app:latest"
    else
        export IMAGE_URI="$SATELLITE_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com/efs-test-app:latest"
    fi
    
    # Substitute environment variables in manifest
    local temp_manifest="/tmp/$account_name-app-manifest.yaml"
    substitute_variables "$manifest_file" "$temp_manifest"
    
    # Apply Kubernetes manifests
    info "Applying Kubernetes manifests"
    kubectl apply -f "$temp_manifest"
    
    # Wait for deployment to be ready
    info "Waiting for deployment to be ready (timeout: 5 minutes)"
    kubectl wait --for=condition=available --timeout=300s deployment/efs-test-app-$account_name -n efs-test
    
    # Get service endpoint
    info "Getting service endpoint"
    local endpoint=""
    local max_attempts=30
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        endpoint=$(kubectl get svc efs-test-app-$account_name-service -n efs-test -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
        if [ -n "$endpoint" ]; then
            break
        fi
        
        # Try IP if hostname is not available
        endpoint=$(kubectl get svc efs-test-app-$account_name-service -n efs-test -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
        if [ -n "$endpoint" ]; then
            break
        fi
        
        info "Waiting for LoadBalancer endpoint... (attempt $((attempt+1))/$max_attempts)"
        sleep 10
        attempt=$((attempt+1))
    done
    
    if [ -z "$endpoint" ]; then
        warn "LoadBalancer endpoint not available after 5 minutes"
        # Get the service details for debugging
        kubectl describe svc efs-test-app-$account_name-service -n efs-test
        endpoint="pending"
    else
        info "Service endpoint: http://$endpoint"
    fi
    
    # Save endpoint information
    echo "${account_name^^}_ENDPOINT=http://$endpoint" >> "${PROJECT_ROOT}/app-endpoints.env"
    
    # Show pod status
    info "Pod status:"
    kubectl get pods -n efs-test -l account=$account_name
    
    # Show recent logs
    info "Recent application logs:"
    kubectl logs -n efs-test -l account=$account_name --tail=10 || true
    
    log "✓ Application deployed successfully to $account_name cluster"
    
    # Cleanup temp files
    rm -f "$temp_manifest"
}

# Test application health
test_application_health() {
    local account_name=$1
    local endpoint_var="${account_name^^}_ENDPOINT"
    local endpoint="${!endpoint_var}"
    
    if [ -z "$endpoint" ] || [ "$endpoint" = "http://pending" ]; then
        warn "Skipping health check for $account_name - endpoint not available"
        return 0
    fi
    
    info "Testing $account_name application health at $endpoint"
    
    local max_attempts=10
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if curl -f -s "$endpoint/health" > /dev/null 2>&1; then
            log "✓ $account_name application is healthy"
            return 0
        fi
        
        info "Health check attempt $((attempt+1))/$max_attempts failed, retrying in 15 seconds..."
        sleep 15
        attempt=$((attempt+1))
    done
    
    warn "Health check failed for $account_name application after $max_attempts attempts"
    return 1
}

# Main function
main() {
    log "Starting EFS Test Application Deployment"
    
    # Check prerequisites
    if ! command -v kubectl &> /dev/null; then
        error "kubectl is required but not installed"
    fi
    
    if ! command -v envsubst &> /dev/null; then
        error "envsubst is required but not installed (install gettext package)"
    fi
    
    # Check if required environment variables are set
    if [ -z "$EFS_COREBANK_ID" ]; then
        error "EFS_COREBANK_ID is not set. Please run deploy-efs-infrastructure.sh first."
    fi
    
    # Initialize app endpoints file
    > "${PROJECT_ROOT}/app-endpoints.env"
    
    # Deploy CoreBank application
    deploy_application "$COREBANK_ACCOUNT" "corebank" "${PROJECT_ROOT}/kubernetes/corebank-app.yaml"
    
    # Deploy Satellite application
    deploy_application "$SATELLITE_ACCOUNT" "satellite" "${PROJECT_ROOT}/kubernetes/satellite-app.yaml"
    
    # Source the endpoints
    source "${PROJECT_ROOT}/app-endpoints.env"
    
    # Test application health
    log "Testing application health..."
    test_application_health "corebank"
    test_application_health "satellite"
    
    log "🎉 EFS Test Applications deployed successfully!"
    log ""
    log "Application endpoints:"
    cat "${PROJECT_ROOT}/app-endpoints.env"
    log ""
    log "Testing commands:"
    if [ -n "$COREBANK_ENDPOINT" ] && [ "$COREBANK_ENDPOINT" != "http://pending" ]; then
        log "  CoreBank Health: curl $COREBANK_ENDPOINT/health"
    fi
    if [ -n "$SATELLITE_ENDPOINT" ] && [ "$SATELLITE_ENDPOINT" != "http://pending" ]; then
        log "  Satellite Health: curl $SATELLITE_ENDPOINT/health"
    fi
    log ""
    log "Next steps:"
    log "1. Run tests: ./scripts/test-efs-cross-account.sh"
    log "2. Monitor applications: kubectl get pods -n efs-test"
}

# Run main function
main "$@"
