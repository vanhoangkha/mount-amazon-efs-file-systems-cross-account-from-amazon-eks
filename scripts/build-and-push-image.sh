#!/bin/bash

# Build and Push EFS Test App to ECR
set -e

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
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

# Configuration
APP_NAME="efs-test-app"
IMAGE_TAG="${IMAGE_TAG:-latest}"
BUILD_DATE=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

# Function to build and push for specific account
build_and_push_for_account() {
    local account_id=$1
    local account_name=$2
    
    log "Building and pushing image for $account_name account ($account_id)"
    
    # ECR repository URI
    local ecr_repo="${account_id}.dkr.ecr.${AWS_REGION}.amazonaws.com/${APP_NAME}"
    
    # Login to ECR
    info "Logging in to ECR for account $account_id"
    aws ecr get-login-password --region $AWS_REGION --profile $account_name | \
        docker login --username AWS --password-stdin $ecr_repo
    
    # Create ECR repository if it doesn't exist
    info "Creating ECR repository if it doesn't exist"
    aws ecr describe-repositories --repository-names $APP_NAME --region $AWS_REGION --profile $account_name 2>/dev/null || \
    aws ecr create-repository \
        --repository-name $APP_NAME \
        --region $AWS_REGION \
        --profile $account_name \
        --image-scanning-configuration scanOnPush=true \
        --encryption-configuration encryptionType=AES256
    
    # Build Docker image
    info "Building Docker image"
    cd "${PROJECT_ROOT}/applications/efs-test-app"
    
    docker build \
        --build-arg BUILD_DATE="$BUILD_DATE" \
        --build-arg GIT_COMMIT="$GIT_COMMIT" \
        --tag $APP_NAME:$IMAGE_TAG \
        --tag $APP_NAME:$GIT_COMMIT \
        --tag $ecr_repo:$IMAGE_TAG \
        --tag $ecr_repo:$GIT_COMMIT \
        .
    
    # Push images to ECR
    info "Pushing images to ECR"
    docker push $ecr_repo:$IMAGE_TAG
    docker push $ecr_repo:$GIT_COMMIT
    
    # Set lifecycle policy
    info "Setting ECR lifecycle policy"
    aws ecr put-lifecycle-policy \
        --repository-name $APP_NAME \
        --region $AWS_REGION \
        --profile $account_name \
        --lifecycle-policy-text '{
            "rules": [
                {
                    "rulePriority": 1,
                    "description": "Keep last 10 images",
                    "selection": {
                        "tagStatus": "tagged",
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
        }'
    
    log "✓ Successfully built and pushed image for $account_name: $ecr_repo:$IMAGE_TAG"
    
    # Return ECR URI for use in deployment
    echo "$ecr_repo:$IMAGE_TAG"
}

# Main function
main() {
    log "Starting EFS Test App build and push process"
    
    # Check prerequisites
    if ! command -v docker &> /dev/null; then
        error "Docker is required but not installed. Install with: curl -fsSL https://get.docker.com -o get-docker.sh && sudo sh get-docker.sh"
    fi
    
    if ! command -v aws &> /dev/null; then
        error "AWS CLI is required but not installed"
    fi
    
    # Build and push for CoreBank account
    COREBANK_ECR_URI=$(build_and_push_for_account "$COREBANK_ACCOUNT" "corebank")
    
    # Build and push for Satellite accounts
    SATELLITE1_ECR_URI=$(build_and_push_for_account "$SATELLITE1_ACCOUNT" "satellite_1")
    SATELLITE2_ECR_URI=$(build_and_push_for_account "$SATELLITE2_ACCOUNT" "satellite_2")
    
    # Save ECR URIs to file for deployment scripts
    cat > "${PROJECT_ROOT}/ecr-uris.env" << EOF
COREBANK_ECR_URI=$COREBANK_ECR_URI
SATELLITE1_ECR_URI=$SATELLITE1_ECR_URI
SATELLITE2_ECR_URI=$SATELLITE2_ECR_URI
EOF
    
    log "🎉 Build and push completed successfully!"
    log ""
    log "ECR URIs:"
    log "  CoreBank: $COREBANK_ECR_URI"
    log "  Satellite_1: $SATELLITE1_ECR_URI"
    log "  Satellite_2: $SATELLITE2_ECR_URI"
    log ""
    log "Next steps:"
    log "1. Deploy EFS infrastructure: ./scripts/deploy-efs-infrastructure.sh"
    log "2. Deploy applications: ./scripts/deploy-efs-test-app.sh"
}

# Run main function
main "$@"
