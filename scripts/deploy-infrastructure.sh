#!/bin/bash

# Cross-Account EFS Infrastructure Deployment Script
# Deploys complete banking infrastructure across 3 AWS accounts

set -e

# Script configuration
PROJECT_ROOT="."


# Load configuration
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

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."
    
    # Check required tools
    for tool in aws kubectl eksctl docker; do
        if ! command -v $tool &> /dev/null; then
            error "$tool is required but not installed"
        fi
    done
    
    # Check AWS CLI profiles
    for profile in corebank satellite; do
        if ! aws sts get-caller-identity --profile $profile &> /dev/null; then
            error "AWS profile '$profile' not configured or credentials invalid"
        fi
    done
    
    # Check environment variables
    if [[ -z "$COREBANK_ACCOUNT" || -z "$SATELLITE_ACCOUNT" ]]; then
        error "Account IDs must be set in environment variables"
    fi
    
    log "✓ Prerequisites check passed"
}

# Main deployment function
main() {
    log "Starting Cross-Account EFS Infrastructure Deployment"
    log "Region: $AWS_REGION"
    log "CoreBank Account: $COREBANK_ACCOUNT"
    log "Satellite Account: $SATELLITE_ACCOUNT"
    
    # Check prerequisites
    check_prerequisites
    
    # Deploy infrastructure components
    "${PROJECT_ROOT}/scripts/deploy-eks-clusters.sh"
    "${PROJECT_ROOT}/scripts/deploy-efs-infrastructure.sh"
    "${PROJECT_ROOT}/scripts/build-and-push-image.sh"
    "${PROJECT_ROOT}/scripts/deploy-efs-test-app.sh"
    
    # Run tests
    "${PROJECT_ROOT}/scripts/test-efs-cross-account.sh"
    
    log "🎉 Cross-Account EFS Infrastructure Deployment Completed Successfully!"
    log ""
    log "Next Steps:"
    log "1. Check application endpoints in app-endpoints.env"
    log "2. Run additional tests: ./scripts/test-efs-cross-account.sh"
    log "3. Check monitoring dashboards in CloudWatch"
    log "4. Review security configurations"
}

# Run main function
main "$@"
