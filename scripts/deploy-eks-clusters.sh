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
    
    # Set VPC CIDR based on account (for display purposes)
    local vpc_cidr
    if [ "$account_name" = "corebank" ]; then
        vpc_cidr="$COREBANK_VPC_CIDR"
    else
        vpc_cidr="$SATELLITE_VPC_CIDR"
    fi
    
    log "Deploying EKS cluster for $account_name account"
    
    # Switch to account
    export AWS_PROFILE="$account_name"
    
    # Check if cluster already exists
    if aws eks describe-cluster --name "$account_name-cluster" --region $AWS_REGION &>/dev/null; then
        warn "EKS cluster $account_name-cluster already exists, skipping creation"
        return 0
    fi
    
    # Get VPC information from deployment environment
    source_deployment_env
    local vpc_id_var="${account_name^^}_VPC_ID"
    local private_subnets_var="${account_name^^}_PRIVATE_SUBNETS"
    local public_subnets_var="${account_name^^}_PUBLIC_SUBNETS"
    
    local vpc_id="${!vpc_id_var}"
    local private_subnets="${!private_subnets_var}"
    local public_subnets="${!public_subnets_var}"
    
    # If deployment environment variables are empty, try to get them from AWS directly
    if [[ -z "$vpc_id" ]]; then
        warn "VPC ID not found in deployment environment, attempting to discover from AWS..."
        vpc_id=$(aws ec2 describe-vpcs \
            --filters "Name=tag:Name,Values=$account_name-vpc" \
            --query 'Vpcs[0].VpcId' \
            --output text \
            --region $AWS_REGION 2>/dev/null || echo "")
        
        if [[ -z "$vpc_id" || "$vpc_id" == "None" ]]; then
            error "VPC not found for $account_name. Please run deploy-vpc.sh first or check your AWS_PROFILE settings."
        fi
        
        info "Discovered VPC ID from AWS: $vpc_id"
    fi
    
    # If subnet information is missing, try to get it from CloudFormation stack
    if [[ -z "$private_subnets" || -z "$public_subnets" ]]; then
        warn "Subnet information not found in deployment environment, attempting to discover from CloudFormation..."
        
        # Check if CloudFormation stack exists
        local stack_exists=$(aws cloudformation describe-stacks \
            --stack-name "$account_name-vpc" \
            --region $AWS_REGION \
            --query 'Stacks[0].StackName' \
            --output text 2>/dev/null || echo "")
        
        if [[ -n "$stack_exists" && "$stack_exists" != "None" ]]; then
            private_subnets=$(aws cloudformation describe-stacks \
                --stack-name "$account_name-vpc" \
                --region $AWS_REGION \
                --query 'Stacks[0].Outputs[?starts_with(OutputKey, `PrivateSubnet`) && ends_with(OutputKey, `Id`)].OutputValue' \
                --output text | tr '\t' ',' 2>/dev/null || echo "")
            
            public_subnets=$(aws cloudformation describe-stacks \
                --stack-name "$account_name-vpc" \
                --region $AWS_REGION \
                --query 'Stacks[0].Outputs[?starts_with(OutputKey, `PublicSubnet`) && ends_with(OutputKey, `Id`)].OutputValue' \
                --output text | tr '\t' ',' 2>/dev/null || echo "")
            
            info "Discovered subnets from CloudFormation stack"
            
            # Update deployment environment for future use
            update_deployment_env "${account_name^^}_VPC_ID" "$vpc_id"
            update_deployment_env "${account_name^^}_PRIVATE_SUBNETS" "$private_subnets"
            update_deployment_env "${account_name^^}_PUBLIC_SUBNETS" "$public_subnets"
        else
            # Try to discover subnets by tags as last resort
            warn "CloudFormation stack not found, attempting to discover subnets by tags..."
            private_subnets=$(aws ec2 describe-subnets \
                --filters "Name=vpc-id,Values=$vpc_id" "Name=tag:Type,Values=private" \
                --query 'Subnets[].SubnetId' \
                --output text \
                --region $AWS_REGION 2>/dev/null | tr '\t' ',' || echo "")
            
            public_subnets=$(aws ec2 describe-subnets \
                --filters "Name=vpc-id,Values=$vpc_id" "Name=tag:Type,Values=public" \
                --query 'Subnets[].SubnetId' \
                --output text \
                --region $AWS_REGION 2>/dev/null | tr '\t' ',' || echo "")
            
            if [[ -n "$private_subnets" || -n "$public_subnets" ]]; then
                info "Discovered subnets by tags"
                # Update deployment environment for future use
                update_deployment_env "${account_name^^}_VPC_ID" "$vpc_id"
                update_deployment_env "${account_name^^}_PRIVATE_SUBNETS" "$private_subnets"
                update_deployment_env "${account_name^^}_PUBLIC_SUBNETS" "$public_subnets"
            fi
        fi
    fi
    
    if [[ -z "$vpc_id" ]]; then
        error "VPC ID not found for $account_name. Please run deploy-vpc.sh first."
    fi
    
    if [[ -z "$private_subnets" ]]; then
        error "Private subnets not found for $account_name. Please run deploy-vpc.sh first."
    fi
    
    if [[ -z "$public_subnets" ]]; then
        error "Public subnets not found for $account_name. Please run deploy-vpc.sh first."
    fi
    
    # Convert comma-separated subnet lists to arrays
    IFS=',' read -ra private_subnet_array <<< "$private_subnets"
    IFS=',' read -ra public_subnet_array <<< "$public_subnets"
    
    # Validate we have enough subnets
    if [[ ${#private_subnet_array[@]} -lt 2 ]]; then
        error "Insufficient private subnets for $account_name. Found ${#private_subnet_array[@]}, need at least 2."
    fi
    
    if [[ ${#public_subnet_array[@]} -lt 2 ]]; then
        error "Insufficient public subnets for $account_name. Found ${#public_subnet_array[@]}, need at least 2."
    fi
    
    info "Using existing VPC: $vpc_id"
    info "Private subnets (${#private_subnet_array[@]}): $private_subnets"
    info "Public subnets (${#public_subnet_array[@]}): $public_subnets"
    
    # Create cluster configuration using existing VPC
    info "Creating EKS cluster configuration for $account_name with existing VPC: $vpc_id"
    cat > /tmp/$account_name-cluster.yaml << EOF
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
EOF

    # Add private subnets dynamically
    if [[ ${#private_subnet_array[@]} -gt 0 ]]; then
        echo "    private:" >> /tmp/$account_name-cluster.yaml
        for subnet in "${private_subnet_array[@]}"; do
            echo "      $subnet: { }" >> /tmp/$account_name-cluster.yaml
        done
    fi

    # Add public subnets dynamically  
    if [[ ${#public_subnet_array[@]} -gt 0 ]]; then
        echo "    public:" >> /tmp/$account_name-cluster.yaml
        for subnet in "${public_subnet_array[@]}"; do
            echo "      $subnet: { }" >> /tmp/$account_name-cluster.yaml
        done
    fi

    # Continue with the rest of the YAML
    cat >> /tmp/$account_name-cluster.yaml << EOF

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
    
    # Display VPC information (already known from deployment environment)
    info "Cluster $account_name-cluster using VPC ID: $vpc_id"
    info "Cluster $account_name-cluster VPC CIDR: $vpc_cidr"
    
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
    
    # Source deployment environment to get VPC information
    source_deployment_env
    
    # Verify VPCs exist
    if [[ -z "${COREBANK_VPC_ID}" || -z "${SATELLITE_VPC_ID}" ]]; then
        error "VPC information not found. Please run deploy-vpc.sh first to create VPCs."
    fi
    
    # Deploy CoreBank EKS cluster
    deploy_eks_cluster "$COREBANK_ACCOUNT" "corebank" "$COREBANK_NODE_TYPE" 2 6 3
    
    # Deploy Satellite EKS cluster
    deploy_eks_cluster "$SATELLITE_ACCOUNT" "satellite" "$SATELLITE_NODE_TYPE" 1 4 2
    
    log "🎉 EKS Clusters deployment completed successfully!"
    log ""
    log "Clusters created:"
    log "  CoreBank: corebank-cluster (VPC: ${COREBANK_VPC_ID})"
    log "  Satellite: satellite-cluster (VPC: ${SATELLITE_VPC_ID})"
    log ""
    log "Next steps:"
    log "1. Deploy EFS infrastructure: ./scripts/deploy-efs-infrastructure.sh"
    log "2. Build and push images: ./scripts/build-and-push-image.sh"
    log "3. Deploy applications: ./scripts/deploy-efs-test-app.sh"
}

# Run main function
main "$@"
