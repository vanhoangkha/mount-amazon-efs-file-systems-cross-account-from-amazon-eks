#!/bin/bash

# Deploy EFS Infrastructure for Cross-Account Testing (Single CoreBank EFS)
set -e

# Load configuration
PROJECT_ROOT="."

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
    aws efs wait file-system-available --file-system-id $EFS_COREBANK_ID --region $AWS_REGION
    
    # Get VPC and subnet information
    VPC_ID=$(aws ec2 describe-vpcs \
        --filters "Name=tag:Name,Values=*corebank*" "Name=state,Values=available" \
        --query 'Vpcs[0].VpcId' \
        --output text \
        --region $AWS_REGION)
    
    if [ "$VPC_ID" = "None" ] || [ -z "$VPC_ID" ]; then
        warn "CoreBank VPC not found, using default VPC"
        VPC_ID=$(aws ec2 describe-vpcs \
            --filters "Name=is-default,Values=true" \
            --query 'Vpcs[0].VpcId' \
            --output text \
            --region $AWS_REGION)
    fi
    
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
    
    # Add NFS rule to security group
    aws ec2 authorize-security-group-ingress \
        --group-id $EFS_SG_ID \
        --protocol tcp \
        --port 2049 \
        --cidr 10.0.0.0/8 \
        --region $AWS_REGION
    
    # Create mount targets
    info "Creating EFS mount targets"
    for subnet_id in $SUBNET_IDS; do
        aws efs create-mount-target \
            --file-system-id $EFS_COREBANK_ID \
            --subnet-id $subnet_id \
            --security-groups $EFS_SG_ID \
            --region $AWS_REGION || true
    done
    
    # Create access points for satellite accounts
    info "Creating access points for satellite accounts"
    
    SATELLITE1_ACCESS_POINT=$(aws efs create-access-point \
        --file-system-id $EFS_COREBANK_ID \
        --posix-user Uid=1001,Gid=1001 \
        --root-directory Path="/satellite1",CreationInfo='{OwnerUid=1001,OwnerGid=1001,Permissions=755}' \
        --tags Key=Name,Value=Satellite1-AccessPoint \
        --region $AWS_REGION \
        --query 'AccessPointId' \
        --output text)
    
    SATELLITE2_ACCESS_POINT=$(aws efs create-access-point \
        --file-system-id $EFS_COREBANK_ID \
        --posix-user Uid=1002,Gid=1002 \
        --root-directory Path="/satellite2",CreationInfo='{OwnerUid=1002,OwnerGid=1002,Permissions=755}' \
        --tags Key=Name,Value=Satellite2-AccessPoint \
        --region $AWS_REGION \
        --query 'AccessPointId' \
        --output text)
    
    info "Access points created:"
    info "  Satellite-1: $SATELLITE1_ACCESS_POINT"
    info "  Satellite-2: $SATELLITE2_ACCESS_POINT"
    
    # Create EFS resource policy for cross-account access
    info "Creating EFS resource policy for cross-account access"
    cat > /tmp/efs-resource-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowCrossAccountAccess",
            "Effect": "Allow",
            "Principal": {
                "AWS": [
                    "arn:aws:iam::$SATELLITE1_ACCOUNT:root",
                    "arn:aws:iam::$SATELLITE2_ACCOUNT:root"
                ]
            },
            "Action": [
                "elasticfilesystem:ClientMount",
                "elasticfilesystem:ClientWrite",
                "elasticfilesystem:ClientRootAccess"
            ],
            "Resource": "*",
            "Condition": {
                "StringEquals": {
                    "elasticfilesystem:AccessPointArn": [
                        "arn:aws:elasticfilesystem:$AWS_REGION:$COREBANK_ACCOUNT:access-point/$SATELLITE1_ACCESS_POINT",
                        "arn:aws:elasticfilesystem:$AWS_REGION:$COREBANK_ACCOUNT:access-point/$SATELLITE2_ACCESS_POINT"
                    ]
                }
            }
        }
    ]
}
EOF
    
    aws efs put-file-system-policy \
        --file-system-id $EFS_COREBANK_ID \
        --policy file:///tmp/efs-resource-policy.json \
        --region $AWS_REGION
    
    # Save outputs
    cat > "${PROJECT_ROOT}/corebank-efs.env" << EOF
EFS_COREBANK_ID=$EFS_COREBANK_ID
SATELLITE1_ACCESS_POINT=$SATELLITE1_ACCESS_POINT
SATELLITE2_ACCESS_POINT=$SATELLITE2_ACCESS_POINT
EFS_SG_ID=$EFS_SG_ID
VPC_ID=$VPC_ID
EOF
    
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
    
    # Save outputs
    cat > "${PROJECT_ROOT}/$account_name-config.env" << EOF
CROSS_ACCOUNT_ROLE_ARN=$ROLE_ARN
ACCOUNT_ID=$account_id
EOF
    
    log "✓ $account_name cross-account configuration completed"
}

# Main function
main() {
    log "Starting EFS Infrastructure Deployment"
    
    # Deploy CoreBank EFS
    deploy_corebank_efs
    
    # Configure Satellite Accounts
    configure_satellite_account "$SATELLITE1_ACCOUNT" "satellite-1"
    configure_satellite_account "$SATELLITE2_ACCOUNT" "satellite-2"
    
    # Combine all environment files
    cat "${PROJECT_ROOT}/corebank-efs.env" \
        "${PROJECT_ROOT}/satellite-1-config.env" \
        "${PROJECT_ROOT}/satellite-2-config.env" \
        > "${PROJECT_ROOT}/efs-infrastructure.env"
    
    log "🎉 EFS Infrastructure deployment completed successfully!"
    log ""
    log "Infrastructure created:"
    log "  CoreBank EFS: $(grep EFS_COREBANK_ID "${PROJECT_ROOT}/corebank-efs.env" | cut -d'=' -f2)"
    log "  Satellite-1 Access Point: $(grep SATELLITE1_ACCESS_POINT "${PROJECT_ROOT}/corebank-efs.env" | cut -d'=' -f2)"
    log "  Satellite-2 Access Point: $(grep SATELLITE2_ACCESS_POINT "${PROJECT_ROOT}/corebank-efs.env" | cut -d'=' -f2)"
    log ""
    log "Next steps:"
    log "1. Deploy EKS clusters: ./scripts/deploy-eks-clusters.sh"
    log "2. Deploy test applications: ./scripts/deploy-efs-test-app.sh"
}

# Run main function
main "$@"
