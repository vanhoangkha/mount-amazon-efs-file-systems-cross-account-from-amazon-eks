#!/bin/bash

# Alternative EKS deployment script with more robust YAML generation
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

# Generate EKS cluster YAML with embedded subnets
generate_eks_yaml() {
    local account_name=$1
    local vpc_id=$2
    local private_subnets=$3
    local public_subnets=$4
    local node_type=$5
    local min_nodes=$6
    local max_nodes=$7
    local desired_nodes=$8
    local vpc_cidr=$9
    
    # Convert comma-separated lists to arrays
    IFS=',' read -ra private_subnet_array <<< "$private_subnets"
    IFS=',' read -ra public_subnet_array <<< "$public_subnets"
    
    # Clean up arrays (remove empty elements and whitespace)
    private_subnet_array=($(printf '%s\n' "${private_subnet_array[@]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$'))
    public_subnet_array=($(printf '%s\n' "${public_subnet_array[@]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$'))
    
    info "Generating YAML for $account_name with ${#private_subnet_array[@]} private and ${#public_subnet_array[@]} public subnets"
    
    # Create the YAML file using a here-document with proper escaping
    cat > /tmp/$account_name-cluster.yaml << 'YAML_END'
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ACCOUNT_NAME-cluster
  region: AWS_REGION_VALUE
  version: "EKS_VERSION_VALUE"

vpc:
  id: VPC_ID_VALUE
  clusterEndpoints:
    privateAccess: true
    publicAccess: true
  subnets:
    private:
PRIVATE_SUBNETS_PLACEHOLDER
    public:
PUBLIC_SUBNETS_PLACEHOLDER

iam:
  withOIDC: true

nodeGroups:
  - name: ACCOUNT_NAME-nodes
    instanceType: NODE_TYPE_VALUE
    minSize: MIN_NODES_VALUE
    maxSize: MAX_NODES_VALUE
    desiredCapacity: DESIRED_NODES_VALUE
    volumeSize: 50
    volumeType: gp3
    
    privateNetworking: true
    
    labels:
      role: ACCOUNT_NAME
      environment: test
    
    tags:
      Environment: test
      Service: ACCOUNT_NAME
      Purpose: efs-testing
      VPC-CIDR: VPC_CIDR_VALUE
    
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
YAML_END

    # Build private subnets section
    local private_subnets_yaml=""
    for subnet in "${private_subnet_array[@]}"; do
        if [[ -n "$subnet" ]]; then
            private_subnets_yaml="${private_subnets_yaml}      ${subnet}: {}\n"
        fi
    done
    
    # Build public subnets section
    local public_subnets_yaml=""
    for subnet in "${public_subnet_array[@]}"; do
        if [[ -n "$subnet" ]]; then
            public_subnets_yaml="${public_subnets_yaml}      ${subnet}: {}\n"
        fi
    done
    
    # Replace placeholders
    sed -i.bak \
        -e "s/ACCOUNT_NAME/$account_name/g" \
        -e "s/AWS_REGION_VALUE/$AWS_REGION/g" \
        -e "s/EKS_VERSION_VALUE/$EKS_VERSION/g" \
        -e "s/VPC_ID_VALUE/$vpc_id/g" \
        -e "s/NODE_TYPE_VALUE/$node_type/g" \
        -e "s/MIN_NODES_VALUE/$min_nodes/g" \
        -e "s/MAX_NODES_VALUE/$max_nodes/g" \
        -e "s/DESIRED_NODES_VALUE/$desired_nodes/g" \
        -e "s/VPC_CIDR_VALUE/$vpc_cidr/g" \
        /tmp/$account_name-cluster.yaml
    
    # Replace subnet placeholders (need to handle newlines properly)
    if [[ -n "$private_subnets_yaml" ]]; then
        sed -i.bak2 "s/PRIVATE_SUBNETS_PLACEHOLDER/$(echo -e "$private_subnets_yaml" | sed 's/$/\\/')/" /tmp/$account_name-cluster.yaml
        sed -i.bak3 's/\\$//' /tmp/$account_name-cluster.yaml  # Remove trailing backslashes
    else
        sed -i.bak2 "s/PRIVATE_SUBNETS_PLACEHOLDER//" /tmp/$account_name-cluster.yaml
    fi
    
    if [[ -n "$public_subnets_yaml" ]]; then
        sed -i.bak4 "s/PUBLIC_SUBNETS_PLACEHOLDER/$(echo -e "$public_subnets_yaml" | sed 's/$/\\/')/" /tmp/$account_name-cluster.yaml
        sed -i.bak5 's/\\$//' /tmp/$account_name-cluster.yaml  # Remove trailing backslashes
    else
        sed -i.bak4 "s/PUBLIC_SUBNETS_PLACEHOLDER//" /tmp/$account_name-cluster.yaml
    fi
    
    # Clean up backup files
    rm -f /tmp/$account_name-cluster.yaml.bak*
    
    info "Generated YAML configuration:"
    cat /tmp/$account_name-cluster.yaml
}

# Deploy EKS cluster with improved YAML generation
deploy_eks_cluster_v2() {
    local account_id=$1
    local account_name=$2
    local node_type=$3
    local min_nodes=$4
    local max_nodes=$5
    local desired_nodes=$6
    
    # Set VPC CIDR based on account (for display purposes)
    local vpc_cidr
    if [ "$account_name" = "corebank" ]; then
        vpc_cidr="$COREBANK_VPC_CIDR"
    else
        vpc_cidr="$SATELLITE_VPC_CIDR"
    fi
    
    log "Deploying EKS cluster for $account_name account (v2 method)"
    
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
    
    # Generate the YAML configuration
    generate_eks_yaml "$account_name" "$vpc_id" "$private_subnets" "$public_subnets" \
                      "$node_type" "$min_nodes" "$max_nodes" "$desired_nodes" "$vpc_cidr"
    
    # Create EKS cluster
    info "Creating EKS cluster $account_name-cluster (this may take 15-20 minutes)"
    eksctl create cluster -f /tmp/$account_name-cluster.yaml
    
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
    log "Starting EKS Clusters Deployment (Alternative Method)"
    
    # Display configuration
    info "Configuration:"
    info "  AWS Region: $AWS_REGION"
    info "  CoreBank Account: $COREBANK_ACCOUNT"
    info "  Satellite Account: $SATELLITE_ACCOUNT"
    
    # Check prerequisites
    if ! command -v eksctl &> /dev/null; then
        error "eksctl is required but not installed"
    fi
    
    # Deploy CoreBank EKS cluster
    deploy_eks_cluster_v2 "$COREBANK_ACCOUNT" "corebank" "$COREBANK_NODE_TYPE" 2 6 3
    
    # Deploy Satellite EKS cluster
    deploy_eks_cluster_v2 "$SATELLITE_ACCOUNT" "satellite" "$SATELLITE_NODE_TYPE" 1 4 2
    
    log "🎉 EKS Clusters deployment completed successfully!"
}

# Run main function
main "$@"
