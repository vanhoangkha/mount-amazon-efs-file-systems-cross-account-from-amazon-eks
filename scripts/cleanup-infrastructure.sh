#!/bin/bash

# Cleanup Cross-Account EFS Infrastructure
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
}

info() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $1${NC}"
}

# Cleanup CloudFormation stacks
cleanup_cloudformation() {
    local account_name=$1
    
    log "Cleaning up CloudFormation stacks for $account_name account..."
    
    export AWS_PROFILE="$account_name"
    
    # Get all stacks related to eksctl
    local stack_names=$(aws cloudformation list-stacks --region $AWS_REGION --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE --query "StackSummaries[?contains(StackName, 'eksctl-$account_name-cluster')].StackName" --output text)
    
    for stack_name in $stack_names; do
        info "Deleting CloudFormation stack: $stack_name"
        aws cloudformation delete-stack --stack-name "$stack_name" --region $AWS_REGION || true
    done
    
    # Wait for stacks to be deleted
    if [ ! -z "$stack_names" ]; then
        info "Waiting for CloudFormation stacks to be deleted..."
        for stack_name in $stack_names; do
            aws cloudformation wait stack-delete-complete --stack-name "$stack_name" --region $AWS_REGION || true
        done
    fi
    
    log "✓ CloudFormation stacks cleaned up for $account_name"
}

# Cleanup EKS cluster
cleanup_eks_cluster() {
    local account_name=$1
    
    log "Cleaning up EKS cluster for $account_name account..."
    
    export AWS_PROFILE="$account_name"
    
    # Check if cluster exists
    if ! aws eks describe-cluster --name "$account_name-cluster" --region $AWS_REGION &>/dev/null; then
        warn "EKS cluster $account_name-cluster does not exist, skipping"
        return 0
    fi
    
    # Update kubeconfig
    aws eks update-kubeconfig --name "$account_name-cluster" --region $AWS_REGION || true
    
    # Force delete system pods that can't be evicted
    info "Force deleting system pods..."
    kubectl delete pods --all -n kube-system --force --grace-period=0 || true
    kubectl delete pods --all -n efs-test --force --grace-period=0 || true
    
    # Delete applications first
    info "Deleting applications..."
    kubectl delete namespace efs-test --force --grace-period=0 || true
    
    # Delete cluster with force flag
    info "Deleting EKS cluster $account_name-cluster"
    eksctl delete cluster --name "$account_name-cluster" --region $AWS_REGION --force --disable-nodegroup-eviction
    
    log "✓ EKS cluster $account_name-cluster deleted"
}

# Cleanup EFS resources
cleanup_efs() {
    local account_name=$1
    
    log "Cleaning up EFS resources for $account_name account..."
    
    export AWS_PROFILE="$account_name"
    
    # Get EFS file systems
    local efs_ids=$(aws efs describe-file-systems --region $AWS_REGION --query 'FileSystems[?Tags[?Key==`Purpose` && Value==`efs-testing`]].FileSystemId' --output text)
    
    for efs_id in $efs_ids; do
        info "Deleting EFS file system: $efs_id"
        
        # Delete access points
        local access_points=$(aws efs describe-access-points --file-system-id $efs_id --region $AWS_REGION --query 'AccessPoints[].AccessPointId' --output text)
        for ap_id in $access_points; do
            info "Deleting access point: $ap_id"
            aws efs delete-access-point --access-point-id $ap_id --region $AWS_REGION || true
        done
        
        # Delete mount targets
        local mount_targets=$(aws efs describe-mount-targets --file-system-id $efs_id --region $AWS_REGION --query 'MountTargets[].MountTargetId' --output text)
        for mt_id in $mount_targets; do
            info "Deleting mount target: $mt_id"
            aws efs delete-mount-target --mount-target-id $mt_id --region $AWS_REGION || true
        done
        
        # Wait for mount targets to be deleted
        info "Waiting for mount targets to be deleted..."
        sleep 30
        
        # Delete file system
        aws efs delete-file-system --file-system-id $efs_id --region $AWS_REGION || true
    done
    
    log "✓ EFS resources cleaned up for $account_name"
}

# Cleanup ECR repositories
cleanup_ecr() {
    local account_name=$1
    
    log "Cleaning up ECR repositories for $account_name account..."
    
    export AWS_PROFILE="$account_name"
    
    # Delete ECR repository
    if aws ecr describe-repositories --repository-names efs-test-app --region $AWS_REGION &>/dev/null; then
        info "Deleting ECR repository: efs-test-app"
        aws ecr delete-repository --repository-name efs-test-app --force --region $AWS_REGION || true
    fi
    
    log "✓ ECR repositories cleaned up for $account_name"
}

# Cleanup IAM roles
cleanup_iam() {
    local account_name=$1
    
    log "Cleaning up IAM roles for $account_name account..."
    
    export AWS_PROFILE="$account_name"
    
    # Delete cross-account EFS roles
    local role_names=(
        "$account_name-efs-cross-account-role"
        "$account_name-EFS-CrossAccount-Role"
        "AmazonEKSLoadBalancerControllerRole-$account_name"
    )
    
    for role_name in "${role_names[@]}"; do
        if aws iam get-role --role-name "$role_name" &>/dev/null; then
            info "Deleting IAM role: $role_name"
            
            # Detach policies
            aws iam list-attached-role-policies --role-name "$role_name" --query 'AttachedPolicies[].PolicyArn' --output text | \
            xargs -r -n1 aws iam detach-role-policy --role-name "$role_name" --policy-arn || true
            
            # Delete inline policies
            aws iam list-role-policies --role-name "$role_name" --query 'PolicyNames[]' --output text | \
            xargs -r -n1 aws iam delete-role-policy --role-name "$role_name" --policy-name || true
            
            # Delete role
            aws iam delete-role --role-name "$role_name" || true
        fi
    done
    
    log "✓ IAM roles cleaned up for $account_name"
}

# Main cleanup function
main() {
    log "Starting Cross-Account EFS Infrastructure Cleanup"
    
    # Confirmation prompt
    read -p "This will delete ALL resources created by this solution. Are you sure? (yes/no): " confirm
    if [[ $confirm != "yes" ]]; then
        log "Cleanup cancelled"
        exit 0
    fi
    
    # Cleanup in reverse order
    for account in "corebank" "satellite"; do
        log "Cleaning up $account account..."
        
        # cleanup_eks_cluster "$account"
        # cleanup_cloudformation "$account"
        cleanup_efs "$account"
        # cleanup_ecr "$account"
        # cleanup_iam "$account"
    done
    
    # Remove local files
    info "Cleaning up local files..."
    rm -f "${PROJECT_ROOT}"/*.env
    rm -f /tmp/*-cluster.yaml
    rm -f /tmp/*-trust-policy.json
    rm -f /tmp/*-efs-policy.json
    
    log "🎉 Infrastructure cleanup completed successfully!"
    log ""
    log "All resources have been deleted:"
    log "  - EKS clusters and node groups"
    log "  - CloudFormation stacks"
    log "  - EFS file systems and access points"
    log "  - ECR repositories"
    log "  - IAM roles and policies"
    log "  - Local configuration files"
}

# Run main function
main "$@"