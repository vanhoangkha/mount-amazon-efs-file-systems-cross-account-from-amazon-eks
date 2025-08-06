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
    
    info "Looking for variables: $vpc_id_var, $private_subnets_var, $public_subnets_var"
    
    local vpc_id="${!vpc_id_var}"
    local private_subnets="${!private_subnets_var}"
    local public_subnets="${!public_subnets_var}"
    
    info "Initial values from deployment environment:"
    info "  vpc_id: '$vpc_id'"
    info "  private_subnets: '$private_subnets'"
    info "  public_subnets: '$public_subnets'"
    
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
    
    # Remove any empty elements and trim whitespace
    private_subnet_array=($(printf '%s\n' "${private_subnet_array[@]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$'))
    public_subnet_array=($(printf '%s\n' "${public_subnet_array[@]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$'))
    
    # Debug output
    info "Raw private_subnets: '$private_subnets'"
    info "Raw public_subnets: '$public_subnets'"
    info "Private subnet array: ${private_subnet_array[@]}"
    info "Public subnet array: ${public_subnet_array[@]}"
    
    # Validate we have enough subnets
    if [[ ${#private_subnet_array[@]} -lt 2 ]]; then
        error "Insufficient private subnets for $account_name. Found ${#private_subnet_array[@]}, need at least 2."
    fi
    
    if [[ ${#public_subnet_array[@]} -lt 2 ]]; then
        error "Insufficient public subnets for $account_name. Found ${#public_subnet_array[@]}, need at least 2."
    fi
    
    # Validate that subnets actually exist and belong to the VPC
    info "Validating subnets exist and belong to VPC: $vpc_id"
    for subnet in "${private_subnet_array[@]}"; do
        local subnet_vpc=$(aws ec2 describe-subnets --subnet-ids "$subnet" --query 'Subnets[0].VpcId' --output text --region $AWS_REGION 2>/dev/null || echo "")
        if [[ "$subnet_vpc" != "$vpc_id" ]]; then
            error "Private subnet $subnet does not belong to VPC $vpc_id (belongs to: $subnet_vpc)"
        fi
        info "✓ Private subnet $subnet validated"
    done
    
    for subnet in "${public_subnet_array[@]}"; do
        local subnet_vpc=$(aws ec2 describe-subnets --subnet-ids "$subnet" --query 'Subnets[0].VpcId' --output text --region $AWS_REGION 2>/dev/null || echo "")
        if [[ "$subnet_vpc" != "$vpc_id" ]]; then
            error "Public subnet $subnet does not belong to VPC $vpc_id (belongs to: $subnet_vpc)"
        fi
        info "✓ Public subnet $subnet validated"
    done
    
    info "Using existing VPC: $vpc_id"
    info "Private subnets (${#private_subnet_array[@]}): $private_subnets"
    info "Public subnets (${#public_subnet_array[@]}): $public_subnets"
    
    # Create cluster configuration using existing VPC
    info "Creating EKS cluster configuration for $account_name with existing VPC: $vpc_id"
    
    # Generate the YAML in a more structured way
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
    private:
EOF

    # Add private subnets with proper formatting
    for subnet in "${private_subnet_array[@]}"; do
        if [[ -n "$subnet" ]]; then
            info "Adding private subnet: $subnet"
            echo "      ${subnet}: {}" >> /tmp/$account_name-cluster.yaml
        fi
    done

    echo "    public:" >> /tmp/$account_name-cluster.yaml
    # Add public subnets with proper formatting
    for subnet in "${public_subnet_array[@]}"; do
        if [[ -n "$subnet" ]]; then
            info "Adding public subnet: $subnet"
            echo "      ${subnet}: {}" >> /tmp/$account_name-cluster.yaml
        fi
    done

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
    
    # Validate the generated YAML
    info "Validating generated YAML configuration..."
    if command -v yq &> /dev/null; then
        if ! yq eval . /tmp/$account_name-cluster.yaml > /dev/null 2>&1; then
            error "Generated YAML is invalid. Please check the configuration."
        fi
        info "✓ YAML syntax validation passed"
    else
        warn "yq not found, skipping YAML syntax validation"
    fi
    
    # Show the final YAML for debugging
    info "Final EKS cluster YAML configuration:"
    cat /tmp/$account_name-cluster.yaml
    
    # Validate with eksctl (dry-run style)
    info "Validating configuration with eksctl..."
    if ! eksctl utils describe-stacks --config-file=/tmp/$account_name-cluster.yaml &>/dev/null; then
        warn "eksctl validation warning - this might still work, continuing..."
    else
        info "✓ eksctl configuration validation passed"
    fi
    
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
    
    # Debug: show what we loaded from deployment environment
    info "Loaded from deployment environment:"
    info "  COREBANK_VPC_ID: ${COREBANK_VPC_ID:-'NOT SET'}"
    info "  SATELLITE_VPC_ID: ${SATELLITE_VPC_ID:-'NOT SET'}"
    info "  COREBANK_PRIVATE_SUBNETS: ${COREBANK_PRIVATE_SUBNETS:-'NOT SET'}"
    info "  COREBANK_PUBLIC_SUBNETS: ${COREBANK_PUBLIC_SUBNETS:-'NOT SET'}"
    info "  SATELLITE_PRIVATE_SUBNETS: ${SATELLITE_PRIVATE_SUBNETS:-'NOT SET'}"
    info "  SATELLITE_PUBLIC_SUBNETS: ${SATELLITE_PUBLIC_SUBNETS:-'NOT SET'}"
    
    # Verify VPCs exist (but don't exit if they're missing - let the deploy function handle discovery)
    if [[ -z "${COREBANK_VPC_ID}" && -z "${SATELLITE_VPC_ID}" ]]; then
        warn "VPC information not found in deployment environment. Will attempt discovery during deployment."
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
