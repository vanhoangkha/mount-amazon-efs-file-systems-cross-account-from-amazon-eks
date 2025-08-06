#!/bin/bash

# Build and Push Docker Images to ECR
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

# Build and push image to ECR
build_and_push_image() {
    local account_id=$1
    local account_name=$2
    
    log "Building and pushing Docker image for $account_name account..."
    
    # Switch to account
    export AWS_PROFILE="$account_name"
    
    # Create ECR repository if it doesn't exist
    info "Creating ECR repository if it doesn't exist"
    aws ecr create-repository \
        --repository-name efs-test-app \
        --region $AWS_REGION \
        --image-scanning-configuration scanOnPush=true \
        --encryption-configuration encryptionType=AES256 \
        2>/dev/null || warn "ECR repository already exists"
    
    # Get ECR login token
    info "Logging into ECR"
    aws ecr get-login-password --region $AWS_REGION | \
        docker login --username AWS --password-stdin $account_id.dkr.ecr.$AWS_REGION.amazonaws.com
    
    # Build Docker image
    local image_tag="$account_id.dkr.ecr.$AWS_REGION.amazonaws.com/efs-test-app:latest"
    info "Building Docker image: $image_tag"
    
    docker build -f "${PROJECT_ROOT}/applications/efs-test-app/Dockerfile" -t efs-test-app "${PROJECT_ROOT}/applications/efs-test-app"
    docker tag efs-test-app:latest $image_tag
    
    # Push image to ECR
    info "Pushing image to ECR"
    docker push $image_tag
    
    log "✓ Docker image built and pushed for $account_name account"
    echo "Image: $image_tag"
}

# Set lifecycle policy for ECR repository
set_ecr_lifecycle_policy() {
    local account_name=$1
    
    info "Setting ECR lifecycle policy for $account_name"
    export AWS_PROFILE="$account_name"
    
    cat > /tmp/ecr-lifecycle-policy.json << EOF
{
    "rules": [
        {
            "rulePriority": 1,
            "description": "Keep last 10 images",
            "selection": {
                "tagStatus": "tagged",
                "tagPrefixList": ["latest", "v"],
                "countType": "imageCountMoreThan",
                "countNumber": 10
            },
            "action": {
                "type": "expire"
            }
        },
        {
            "rulePriority": 2,
            "description": "Delete untagged images older than 1 day",
            "selection": {
                "tagStatus": "untagged",
                "countType": "sinceImagePushed",
                "countUnit": "days",
                "countNumber": 1
            },
            "action": {
                "type": "expire"
            }
        }
    ]
}
EOF
    
    aws ecr put-lifecycle-policy \
        --repository-name efs-test-app \
        --lifecycle-policy-text file:///tmp/ecr-lifecycle-policy.json \
        --region $AWS_REGION
}

# Main function
main() {
    log "Starting Docker image build and push process"
    log "CoreBank Account: $COREBANK_ACCOUNT (VPC CIDR: $COREBANK_VPC_CIDR)"
    log "Satellite Account: $SATELLITE_ACCOUNT (VPC CIDR: $SATELLITE_VPC_CIDR)"
    
    # Check prerequisites
    if ! command -v docker &> /dev/null; then
        error "Docker is required but not installed"
    fi
    
    # Check if Docker daemon is running
    if ! docker info &> /dev/null; then
        error "Docker daemon is not running"
    fi
    
    # Build and push for CoreBank account
    build_and_push_image "$COREBANK_ACCOUNT" "corebank"
    set_ecr_lifecycle_policy "corebank"
    
    # Build and push for Satellite account
    build_and_push_image "$SATELLITE_ACCOUNT" "satellite"
    set_ecr_lifecycle_policy "satellite"
    
    # Save image information to unified environment file
    update_deployment_env "COREBANK_IMAGE" "$COREBANK_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com/efs-test-app:latest"
    update_deployment_env "SATELLITE_IMAGE" "$SATELLITE_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com/efs-test-app:latest"
    
    log "🎉 Docker images built and pushed successfully!"
    log ""
    log "Images created:"
    log "  CoreBank: $COREBANK_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com/efs-test-app:latest"
    log "  Satellite: $SATELLITE_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com/efs-test-app:latest"
    log ""
    log "Next steps:"
    log "1. Deploy applications: ./scripts/deploy-efs-test-app.sh"
    log "2. Run tests: ./scripts/test-efs-cross-account.sh"
}

# Run main function
main "$@"
