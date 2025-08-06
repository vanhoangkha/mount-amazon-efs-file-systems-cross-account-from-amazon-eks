#!/bin/bash

# Simple and robust EKS deployment script
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

# Simple and robust EKS cluster deployment
deploy_eks_cluster_simple() {
    local account_id=$1
    local account_name=$2
    local node_type=$3
    local min_nodes=$4
    local max_nodes=$5
    local desired_nodes=$6
    
    log "Deploying EKS cluster for $account_name account (simple method)"
    
    # Switch to account
    export AWS_PROFILE="$account_name"
    
    # Check if cluster already exists
    if aws eks describe-cluster --name "$account_name-cluster" --region $AWS_REGION &>/dev/null; then
        warn "EKS cluster $account_name-cluster already exists, skipping creation"
        return 0
    fi
    
    # Get VPC information
    source_deployment_env
    local vpc_id_var="${account_name^^}_VPC_ID"
    local private_subnets_var="${account_name^^}_PRIVATE_SUBNETS"
    local public_subnets_var="${account_name^^}_PUBLIC_SUBNETS"
    
    local vpc_id="${!vpc_id_var}"
    local private_subnets="${!private_subnets_var}"
    local public_subnets="${!public_subnets_var}"
    
    info "Configuration for $account_name:"
    info "  VPC ID: $vpc_id"
    info "  Private Subnets: $private_subnets"
    info "  Public Subnets: $public_subnets"
    
    # Validate required information
    if [[ -z "$vpc_id" || -z "$private_subnets" || -z "$public_subnets" ]]; then
        error "Missing VPC or subnet information for $account_name. Please run deploy-vpc.sh first."
    fi
    
    # Convert to arrays and clean up
    IFS=',' read -ra private_subnet_array <<< "$private_subnets"
    IFS=',' read -ra public_subnet_array <<< "$public_subnets"
    
    # Trim whitespace from each element
    for i in "${!private_subnet_array[@]}"; do
        private_subnet_array[$i]=$(echo "${private_subnet_array[$i]}" | xargs)
    done
    
    for i in "${!public_subnet_array[@]}"; do
        public_subnet_array[$i]=$(echo "${public_subnet_array[$i]}" | xargs)
    done
    
    # Remove empty elements
    private_subnet_array=($(printf '%s\n' "${private_subnet_array[@]}" | grep -v '^$'))
    public_subnet_array=($(printf '%s\n' "${public_subnet_array[@]}" | grep -v '^$'))
    
    info "Cleaned subnet arrays:"
    info "  Private (${#private_subnet_array[@]}): ${private_subnet_array[*]}"
    info "  Public (${#public_subnet_array[@]}): ${public_subnet_array[*]}"
    
    # Validate we have enough subnets
    if [[ ${#private_subnet_array[@]} -lt 2 ]]; then
        error "Need at least 2 private subnets, found ${#private_subnet_array[@]}"
    fi
    
    if [[ ${#public_subnet_array[@]} -lt 2 ]]; then
        error "Need at least 2 public subnets, found ${#public_subnet_array[@]}"
    fi
    
    # Generate YAML configuration directly
    local yaml_file="/tmp/$account_name-cluster.yaml"
    info "Creating EKS cluster configuration: $yaml_file"
    
    cat > "$yaml_file" << EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: $account_name-cluster
  region: $AWS_REGION
  version: "$EKS_VERSION"

vpc:
  id: $vpc_id
  clusterEndpoints:
    privateAccess: true
    publicAccess: true
  subnets:
    private:
EOF

    # Add private subnets
    for subnet in "${private_subnet_array[@]}"; do
        echo "      $subnet: {}" >> "$yaml_file"
    done

    echo "    public:" >> "$yaml_file"
    
    # Add public subnets
    for subnet in "${public_subnet_array[@]}"; do
        echo "      $subnet: {}" >> "$yaml_file"
    done

    # Complete the YAML
    cat >> "$yaml_file" << EOF

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
    privateNetworking: true
    
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

    # Show the generated configuration
    info "Generated EKS cluster configuration:"
    echo "----------------------------------------"
    cat "$yaml_file"
    echo "----------------------------------------"
    
    # Validate YAML syntax if possible
    if command -v yq &> /dev/null; then
        if yq eval . "$yaml_file" > /dev/null 2>&1; then
            info "✓ YAML syntax validation passed"
        else
            error "Generated YAML has syntax errors"
        fi
    fi
    
    # Ask for confirmation before proceeding
    echo ""
    read -p "Proceed with EKS cluster creation? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        warn "EKS cluster creation cancelled by user"
        return 0
    fi
    
    # Create EKS cluster
    info "Creating EKS cluster $account_name-cluster (this may take 15-20 minutes)"
    eksctl create cluster -f "$yaml_file"
    
    # Update kubeconfig
    info "Updating kubeconfig for $account_name-cluster"
    aws eks update-kubeconfig --region $AWS_REGION --name "$account_name-cluster" --alias "$account_name-cluster"
    
    # Verify cluster
    info "Verifying cluster nodes"
    kubectl get nodes --context "$account_name-cluster"
    
    log "✓ EKS cluster $account_name-cluster deployed successfully"
}

# Main function
main() {
    log "Starting Simple EKS Clusters Deployment"
    
    # Display configuration
    info "Configuration:"
    info "  AWS Region: $AWS_REGION"
    info "  CoreBank Account: $COREBANK_ACCOUNT"
    info "  Satellite Account: $SATELLITE_ACCOUNT"
    
    # Check prerequisites
    if ! command -v eksctl &> /dev/null; then
        error "eksctl is required but not installed"
    fi
    
    if ! command -v kubectl &> /dev/null; then
        error "kubectl is required but not installed"
    fi
    
    # Deploy CoreBank EKS cluster
    deploy_eks_cluster_simple "$COREBANK_ACCOUNT" "corebank" "$COREBANK_NODE_TYPE" 2 6 3
    
    # Deploy Satellite EKS cluster
    deploy_eks_cluster_simple "$SATELLITE_ACCOUNT" "satellite" "$SATELLITE_NODE_TYPE" 1 4 2
    
    log "🎉 EKS Clusters deployment completed successfully!"
}

# Run main function
main "$@"
