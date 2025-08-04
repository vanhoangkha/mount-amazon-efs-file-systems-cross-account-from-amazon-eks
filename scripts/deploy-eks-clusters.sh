#!/bin/bash

# Deploy EKS Clusters for EFS Testing
set -e

# Load configuration
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${PROJECT_ROOT}/scripts/config.sh"

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

# Deploy EKS cluster
deploy_eks_cluster() {
    local account_id=$1
    local account_name=$2
    local node_type=$3
    local min_nodes=$4
    local max_nodes=$5
    local desired_nodes=$6
    
    log "Deploying EKS cluster for $account_name account..."
    
    # Switch to account
    export AWS_PROFILE="$account_name"
    
    # Check if cluster already exists
    if aws eks describe-cluster --name "$account_name-cluster" --region $AWS_REGION &>/dev/null; then
        warn "EKS cluster $account_name-cluster already exists, skipping creation"
        return 0
    fi
    
    # Create cluster configuration
    info "Creating EKS cluster configuration for $account_name"
    cat > /tmp/$account_name-cluster.yaml << EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: $account_name-cluster
  region: $AWS_REGION
  version: "$EKS_VERSION"

iam:
  withOIDC: true

nodeGroups:
  - name: $account_name-nodes
    instanceType: $node_type
    minSize: $min_nodes
    maxSize: $max_nodes
    desiredCapacity: $desired_nodes
    volumeSize: 50
    volumeType: gp3
    
    labels:
      role: $account_name
      environment: test
    
    tags:
      Environment: test
      Service: $account_name
      Purpose: efs-testing
    
    iam:
      attachPolicyARNs:
        - arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
        - arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
        - arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
        - arn:aws:iam::aws:policy/AmazonElasticFileSystemClientFullAccess

addons:
  - name: vpc-cni
    version: latest
  - name: coredns
    version: latest
  - name: kube-proxy
    version: latest
  - name: aws-efs-csi-driver
    version: latest

cloudWatch:
  clusterLogging:
    enableTypes: ["api", "audit", "authenticator", "controllerManager", "scheduler"]
EOF
    
    # Create EKS cluster
    info "Creating EKS cluster $account_name-cluster (this may take 15-20 minutes)"
    eksctl create cluster -f /tmp/$account_name-cluster.yaml
    
    # Update kubeconfig
    info "Updating kubeconfig for $account_name-cluster"
    aws eks update-kubeconfig --region $AWS_REGION --name "$account_name-cluster" --alias "$account_name-cluster"
    
    # Verify cluster
    info "Verifying cluster nodes"
    kubectl get nodes --context "$account_name-cluster"
    
    # Create service account for EFS CSI driver
    info "Creating service account for EFS CSI driver"
    eksctl create iamserviceaccount \
        --cluster="$account_name-cluster" \
        --namespace=kube-system \
        --name=efs-csi-controller-sa \
        --attach-policy-arn=arn:aws:iam::aws:policy/AmazonElasticFileSystemClientFullAccess \
        --approve \
        --region=$AWS_REGION
    
    log "✓ EKS cluster $account_name-cluster deployed successfully"
}

# Main function
main() {
    log "Starting EKS Clusters Deployment"
    
    # Check prerequisites
    if ! command -v eksctl &> /dev/null; then
        error "eksctl is required but not installed"
    fi
    
    # Deploy CoreBank EKS cluster
    deploy_eks_cluster "$COREBANK_ACCOUNT" "corebank" "$COREBANK_NODE_TYPE" 2 6 3
    
    # Deploy Satellite EKS clusters
    deploy_eks_cluster "$SATELLITE1_ACCOUNT" "satellite_1" "$SATELLITE_NODE_TYPE" 1 4 2
    deploy_eks_cluster "$SATELLITE2_ACCOUNT" "satellite_2" "$SATELLITE_NODE_TYPE" 1 4 2
    
    log "🎉 EKS Clusters deployment completed successfully!"
    log ""
    log "Clusters created:"
    log "  CoreBank: corebank-cluster"
    log "  Satellite_1: satellite_1-cluster"
    log "  Satellite_2: satellite_2-cluster"
    log ""
    log "Next steps:"
    log "1. Deploy EFS infrastructure: ./scripts/deploy-efs-infrastructure.sh"
    log "2. Build and push images: ./scripts/build-and-push-image.sh"
    log "3. Deploy applications: ./scripts/deploy-efs-test-app.sh"
}

# Run main function
main "$@"
