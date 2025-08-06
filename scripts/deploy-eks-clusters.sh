#!/bin/bash

# Deploy EKS Clusters for EFS Testing
set -e

PROJECT_ROOT="."
source ./scripts/config.sh

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
    
    # Set VPC CIDR based on account
    local vpc_cidr
    if [ "$account_name" = "corebank" ]; then
        vpc_cidr="$COREBANK_VPC_CIDR"
    else
        vpc_cidr="$SATELLITE_VPC_CIDR"
    fi
    
    log "Deploying EKS cluster for $account_name account with VPC CIDR: $vpc_cidr"
    
    # Switch to account
    export AWS_PROFILE="$account_name"
    
    # Check if cluster already exists
    if aws eks describe-cluster --name "$account_name-cluster" --region $AWS_REGION &>/dev/null; then
        warn "EKS cluster $account_name-cluster already exists, skipping creation"
        return 0
    fi
    
    # Create cluster configuration
    info "Creating EKS cluster configuration for $account_name with VPC CIDR: $vpc_cidr"
    cat > /tmp/$account_name-cluster.yaml << EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: $account_name-cluster
  region: $AWS_REGION
  version: "$EKS_VERSION"

vpc:
  cidr: $vpc_cidr
  clusterEndpoints:
    privateAccess: true
    publicAccess: true
  subnets:
    private:
      $AWS_REGION-a:
        cidr: ${vpc_cidr%.*}.0/24
      $AWS_REGION-b:
        cidr: ${vpc_cidr%.*}.1/24
      $AWS_REGION-c:
        cidr: ${vpc_cidr%.*}.2/24
    public:
      $AWS_REGION-a:
        cidr: ${vpc_cidr%.*}.100/24
      $AWS_REGION-b:
        cidr: ${vpc_cidr%.*}.101/24
      $AWS_REGION-c:
        cidr: ${vpc_cidr%.*}.102/24

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
    
    subnets:
      - $AWS_REGION-a
      - $AWS_REGION-b
      - $AWS_REGION-c
    
    labels:
      role: $account_name
      environment: test
    
    tags:
      Environment: test
      Service: $account_name
      Purpose: efs-testing
      VPC-CIDR: $vpc_cidr
    
    iam:
      attachPolicyARNs:
        - arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
        - arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
        - arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
        - arn:aws:iam::aws:policy/AmazonElasticFileSystemClientFullAccess
        - arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy
        - arn:aws:iam::aws:policy/AmazonEKSClusterPolicy

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
    
    # Display VPC information
    info "Getting VPC information for $account_name-cluster"
    VPC_ID=$(aws ec2 describe-vpcs \
        --filters "Name=tag:eksctl.cluster.k8s.io/v1alpha1/cluster-name,Values=$account_name-cluster" \
        --query 'Vpcs[0].VpcId' \
        --output text \
        --region $AWS_REGION)
    
    VPC_CIDR=$(aws ec2 describe-vpcs \
        --vpc-ids $VPC_ID \
        --query 'Vpcs[0].CidrBlock' \
        --output text \
        --region $AWS_REGION)
    
    info "Cluster $account_name-cluster VPC ID: $VPC_ID"
    info "Cluster $account_name-cluster VPC CIDR: $VPC_CIDR"
    
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
    
    # Display VPC configuration
    info "VPC Configuration:"
    info "  CoreBank VPC CIDR: $COREBANK_VPC_CIDR"
    info "  Satellite VPC CIDR: $SATELLITE_VPC_CIDR"
    
    # Check prerequisites
    if ! command -v eksctl &> /dev/null; then
        error "eksctl is required but not installed"
    fi
    
    # Deploy CoreBank EKS cluster
    deploy_eks_cluster "$COREBANK_ACCOUNT" "corebank" "$COREBANK_NODE_TYPE" 2 6 3
    
    # Deploy Satellite EKS cluster
    deploy_eks_cluster "$SATELLITE_ACCOUNT" "satellite" "$SATELLITE_NODE_TYPE" 1 4 2
    
    log "🎉 EKS Clusters deployment completed successfully!"
    log ""
    log "Clusters created:"
    log "  CoreBank: corebank-cluster (VPC CIDR: $COREBANK_VPC_CIDR)"
    log "  Satellite: satellite-cluster (VPC CIDR: $SATELLITE_VPC_CIDR)"
    log ""
    log "Next steps:"
    log "1. Deploy EFS infrastructure: ./scripts/deploy-efs-infrastructure.sh"
    log "2. Build and push images: ./scripts/build-and-push-image.sh"
    log "3. Deploy applications: ./scripts/deploy-efs-test-app.sh"
}

# Run main function
main "$@"
