#!/bin/bash

# Deploy EFS Infrastructure for Cross-Account Testing (Single CoreBank EFS)
set -e

PROJECT_ROOT="."
source ./scripts/config.sh

# Source deployment environment
source_deployment_env

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

# Deploy CoreBank EFS
deploy_corebank_efs() {
    log "Deploying CoreBank EFS..."
    
    # Switch to CoreBank account
    export AWS_PROFILE="corebank"
    
    # Create EFS file system
    info "Creating CoreBank EFS file system"
    EFS_COREBANK_ID=$(aws efs create-file-system \
        --creation-token "corebank-efs-$(date +%s)" \
        --performance-mode generalPurpose \
        --throughput-mode provisioned \
        --provisioned-throughput-in-mibps $EFS_COREBANK_THROUGHPUT \
        --encrypted \
        --tags Key=Name,Value=CoreBank-EFS Key=Environment,Value=test \
        --region $AWS_REGION \
        --query 'FileSystemId' \
        --output text)
    
    info "CoreBank EFS created: $EFS_COREBANK_ID"
    
    # Wait for EFS to be available
    info "Waiting for EFS to be available..."
    while true; do
        EFS_STATE=$(aws efs describe-file-systems --file-system-id $EFS_COREBANK_ID --region $AWS_REGION --query 'FileSystems[0].LifeCycleState' --output text)
        if [ "$EFS_STATE" = "available" ]; then
            info "EFS is now available"
            break
        fi
        info "EFS state: $EFS_STATE, waiting..."
        sleep 10
    done
    
    # Get VPC and subnet information for the CoreBank EKS cluster
    info "Looking for CoreBank EKS cluster VPC..."
    VPC_ID=$(aws ec2 describe-vpcs \
        --filters "Name=tag:eksctl.cluster.k8s.io/v1alpha1/cluster-name,Values=corebank-cluster" "Name=state,Values=available" \
        --query 'Vpcs[0].VpcId' \
        --output text \
        --region $AWS_REGION)
    
    if [ "$VPC_ID" = "None" ] || [ -z "$VPC_ID" ]; then
        # Fallback to looking for VPC with CoreBank tag
        info "EKS cluster VPC not found, looking for tagged CoreBank VPC..."
        VPC_ID=$(aws ec2 describe-vpcs \
            --filters "Name=tag:Name,Values=*corebank*" "Name=state,Values=available" \
            --query 'Vpcs[0].VpcId' \
            --output text \
            --region $AWS_REGION)
    fi
    
    if [ "$VPC_ID" = "None" ] || [ -z "$VPC_ID" ]; then
        warn "CoreBank VPC not found, using default VPC"
        VPC_ID=$(aws ec2 describe-vpcs \
            --filters "Name=is-default,Values=true" \
            --query 'Vpcs[0].VpcId' \
            --output text \
            --region $AWS_REGION)
    fi
    
    info "Using VPC: $VPC_ID"
    
    # Get subnets
    SUBNET_IDS=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available" \
        --query 'Subnets[*].SubnetId' \
        --output text \
        --region $AWS_REGION)
    
    # Create security group for EFS
    info "Creating EFS security group"
    EFS_SG_ID=$(aws ec2 create-security-group \
        --group-name efs-corebank-sg \
        --description "Security group for CoreBank EFS" \
        --vpc-id $VPC_ID \
        --region $AWS_REGION \
        --query 'GroupId' \
        --output text)
    
    # Add NFS rule to security group for CoreBank VPC CIDR
    VPC_CIDR=$(aws ec2 describe-vpcs \
        --vpc-ids $VPC_ID \
        --query 'Vpcs[0].CidrBlock' \
        --output text \
        --region $AWS_REGION)
    
    info "Adding CoreBank VPC CIDR to security group: $VPC_CIDR"
    aws ec2 authorize-security-group-ingress \
        --group-id $EFS_SG_ID \
        --protocol tcp \
        --port 2049 \
        --cidr $VPC_CIDR \
        --region $AWS_REGION
    
    # Add specific CIDR ranges for cross-account access (CoreBank and Satellite VPCs)
    info "Adding CoreBank VPC CIDR: $COREBANK_VPC_CIDR"
    aws ec2 authorize-security-group-ingress \
        --group-id $EFS_SG_ID \
        --protocol tcp \
        --port 2049 \
        --cidr $COREBANK_VPC_CIDR \
        --region $AWS_REGION || true
    
    info "Adding Satellite VPC CIDR: $SATELLITE_VPC_CIDR"    
    aws ec2 authorize-security-group-ingress \
        --group-id $EFS_SG_ID \
        --protocol tcp \
        --port 2049 \
        --cidr $SATELLITE_VPC_CIDR \
        --region $AWS_REGION || true
    
    # Create mount targets
    info "Creating EFS mount targets"
    for subnet_id in $SUBNET_IDS; do
        aws efs create-mount-target \
            --file-system-id $EFS_COREBANK_ID \
            --subnet-id $subnet_id \
            --security-groups $EFS_SG_ID \
            --region $AWS_REGION || true
    done
    
    # Create access point for satellite account
    info "Creating access point for satellite account"
    
    SATELLITE_ACCESS_POINT=$(aws efs create-access-point \
        --file-system-id $EFS_COREBANK_ID \
        --posix-user Uid=1001,Gid=1001 \
        --root-directory Path="/satellite",CreationInfo='{OwnerUid=1001,OwnerGid=1001,Permissions=0755}' \
        --tags Key=Name,Value=Satellite-AccessPoint Key=Account,Value=satellite \
        --region $AWS_REGION \
        --query 'AccessPointId' \
        --output text)
    
    # Wait for access point to be available
    info "Waiting for access point to be available..."
    while true; do
        AP_STATE=$(aws efs describe-access-points --access-point-id $SATELLITE_ACCESS_POINT --region $AWS_REGION --query 'AccessPoints[0].LifeCycleState' --output text)
        if [ "$AP_STATE" = "available" ]; then
            info "Access point is now available"
            break
        fi
        info "Access point state: $AP_STATE, waiting..."
        sleep 5
    done
    
    info "Access point created:"
    info "  Satellite: $SATELLITE_ACCESS_POINT"
    
    # Create EFS resource policy for cross-account access
    info "Creating EFS resource policy for cross-account access"
    cat > /tmp/efs-resource-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowCrossAccountAccessViaSatelliteAccessPoint",
            "Effect": "Allow",
            "Principal": {
                "AWS": [
                    "arn:aws:iam::$SATELLITE_ACCOUNT:root"
                ]
            },
            "Action": [
                "elasticfilesystem:ClientMount",
                "elasticfilesystem:ClientWrite",
                "elasticfilesystem:ClientRootAccess"
            ],
            "Resource": "arn:aws:elasticfilesystem:$AWS_REGION:$COREBANK_ACCOUNT:file-system/$EFS_COREBANK_ID",
            "Condition": {
                "StringEquals": {
                    "elasticfilesystem:AccessPointArn": "arn:aws:elasticfilesystem:$AWS_REGION:$COREBANK_ACCOUNT:access-point/$SATELLITE_ACCESS_POINT"
                }
            }
        },
        {
            "Sid": "AllowSatelliteAccountIAMAccess",
            "Effect": "Allow",
            "Principal": {
                "AWS": [
                    "arn:aws:iam::$SATELLITE_ACCOUNT:root"
                ]
            },
            "Action": [
                "elasticfilesystem:ClientMount",
                "elasticfilesystem:ClientWrite",
                "elasticfilesystem:ClientRootAccess"
            ],
            "Resource": "arn:aws:elasticfilesystem:$AWS_REGION:$COREBANK_ACCOUNT:file-system/$EFS_COREBANK_ID"
        },
        {
            "Sid": "AllowCoreAccountFullAccess",
            "Effect": "Allow",
            "Principal": {
                "AWS": "arn:aws:iam::$COREBANK_ACCOUNT:root"
            },
            "Action": [
                "elasticfilesystem:*"
            ],
            "Resource": "arn:aws:elasticfilesystem:$AWS_REGION:$COREBANK_ACCOUNT:file-system/$EFS_COREBANK_ID"
        }
    ]
}
EOF
    
    aws efs put-file-system-policy \
        --file-system-id $EFS_COREBANK_ID \
        --policy file:///tmp/efs-resource-policy.json \
        --region $AWS_REGION
    
    # Save outputs to unified environment file
    update_deployment_env "EFS_COREBANK_ID" "$EFS_COREBANK_ID"
    update_deployment_env "SATELLITE_ACCESS_POINT" "$SATELLITE_ACCESS_POINT"
    update_deployment_env "EFS_SG_ID" "$EFS_SG_ID"
    update_deployment_env "VPC_ID" "$VPC_ID"
    
    log "✓ CoreBank EFS deployment completed"
}

# Configure Satellite Account for Cross-Account EFS Access
configure_satellite_account() {
    local account_id=$1
    local account_name=$2
    
    log "Configuring $account_name for cross-account EFS access..."
    
    # Switch to satellite account
    export AWS_PROFILE="$account_name"
    
    # Create IAM role for cross-account EFS access
    info "Creating cross-account EFS access role"
    
    # Create trust policy
    cat > /tmp/trust-policy-$account_name.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "eks.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        },
        {
            "Effect": "Allow",
            "Principal": {
                "AWS": "arn:aws:iam::$account_id:root"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF
    
    # Create EFS access policy
    cat > /tmp/efs-policy-$account_name.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "elasticfilesystem:ClientMount",
                "elasticfilesystem:ClientWrite",
                "elasticfilesystem:ClientRootAccess",
                "elasticfilesystem:DescribeFileSystems",
                "elasticfilesystem:DescribeAccessPoints"
            ],
            "Resource": "*"
        }
    ]
}
EOF
    
    # Create IAM role
    ROLE_ARN=$(aws iam create-role \
        --role-name "$account_name-efs-cross-account-role" \
        --assume-role-policy-document file:///tmp/trust-policy-$account_name.json \
        --region $AWS_REGION \
        --query 'Role.Arn' \
        --output text 2>/dev/null || \
        aws iam get-role \
        --role-name "$account_name-efs-cross-account-role" \
        --query 'Role.Arn' \
        --output text)
    
    # Attach policy to role
    aws iam put-role-policy \
        --role-name "$account_name-efs-cross-account-role" \
        --policy-name "EFSCrossAccountAccess" \
        --policy-document file:///tmp/efs-policy-$account_name.json \
        --region $AWS_REGION
    
    info "Cross-account role created: $ROLE_ARN"
    
    # Save outputs to unified environment file
    update_deployment_env "SATELLITE_CROSS_ACCOUNT_ROLE_ARN" "$ROLE_ARN"
    
    log "✓ $account_name cross-account configuration completed"
}

# Main function
main() {
    log "Starting EFS Infrastructure Deployment"
    
    # Deploy CoreBank EFS
    deploy_corebank_efs
    
    # Configure Satellite Account
    configure_satellite_account "$SATELLITE_ACCOUNT" "satellite"
    
    log "🎉 EFS Infrastructure deployment completed successfully!"
    log ""
    log "Infrastructure created:"
    log "  CoreBank EFS: $EFS_COREBANK_ID"
    log "  Satellite Access Point: $SATELLITE_ACCESS_POINT"
    log "  Environment file: $DEPLOYMENT_ENV_FILE"
    log ""
    log "Next steps:"
    log "1. Build and push images: ./scripts/build-and-push-image.sh"
    log "2. Deploy test applications: ./scripts/deploy-efs-test-app.sh"
}

# Run main function
main "$@"
