#!/bin/bash

# Configuration file for cross-account EFS deployment

# AWS Account Configuration
export COREBANK_ACCOUNT="${COREBANK_ACCOUNT:-111111111111}"
export SATELLITE_ACCOUNT="${SATELLITE_ACCOUNT:-222222222222}"
export AWS_REGION="${AWS_REGION:-ap-southeast-1}"

# EKS Configuration
export EKS_VERSION="${EKS_VERSION:-1.28}"
export COREBANK_NODE_TYPE="${COREBANK_NODE_TYPE:-c5.xlarge}"
export SATELLITE_NODE_TYPE="${SATELLITE_NODE_TYPE:-c5.large}"

# VPC Configuration
export COREBANK_VPC_CIDR="${COREBANK_VPC_CIDR:-10.1.0.0/16}"
export SATELLITE_VPC_CIDR="${SATELLITE_VPC_CIDR:-10.2.0.0/16}"

# EFS Configuration
export EFS_COREBANK_THROUGHPUT="${EFS_COREBANK_THROUGHPUT:-1000}"

# Performance Configuration
export WRITE_TIMEOUT="${WRITE_TIMEOUT:-30}"
export API_RESPONSE_TARGET="${API_RESPONSE_TARGET:-200}"
export RECOVERY_TIME_TARGET="${RECOVERY_TIME_TARGET:-60}"

# Application Configuration
export COREBANK_REPLICAS="${COREBANK_REPLICAS:-6}"
export SATELLITE_REPLICAS="${SATELLITE_REPLICAS:-3}"

# Monitoring Configuration
export METRICS_INTERVAL="${METRICS_INTERVAL:-30}"
export HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL:-10}"

# Backup Configuration
export BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
export AUDIT_RETENTION_DAYS="${AUDIT_RETENTION_DAYS:-2555}"

# Environment File Management
export DEPLOYMENT_ENV_FILE="${PROJECT_ROOT:-./}/deployment.env"

# Initialize deployment environment file
init_deployment_env() {
    if [ ! -f "$DEPLOYMENT_ENV_FILE" ]; then
        cat > "$DEPLOYMENT_ENV_FILE" << EOF
# Cross-Account EFS Deployment Environment
# Generated on $(date)

# AWS Configuration
export AWS_REGION=$AWS_REGION
export COREBANK_ACCOUNT=$COREBANK_ACCOUNT
export SATELLITE_ACCOUNT=$SATELLITE_ACCOUNT

# VPC Configuration
export COREBANK_VPC_CIDR=$COREBANK_VPC_CIDR
export SATELLITE_VPC_CIDR=$SATELLITE_VPC_CIDR

# EKS Configuration
export EKS_VERSION=$EKS_VERSION
export COREBANK_NODE_TYPE=$COREBANK_NODE_TYPE
export SATELLITE_NODE_TYPE=$SATELLITE_NODE_TYPE

# Application Configuration
export COREBANK_REPLICAS=$COREBANK_REPLICAS
export SATELLITE_REPLICAS=$SATELLITE_REPLICAS
export WRITE_TIMEOUT=$WRITE_TIMEOUT

# Infrastructure Variables (populated during deployment)
export EFS_COREBANK_ID=""
export SATELLITE_ACCESS_POINT=""
export COREBANK_ENDPOINT=""
export SATELLITE_ENDPOINT=""
export COREBANK_IMAGE=""
export SATELLITE_IMAGE=""
EOF
    fi
}

# Update deployment environment variable
update_deployment_env() {
    local var_name=$1
    local var_value=$2
    
    if [ -f "$DEPLOYMENT_ENV_FILE" ]; then
        # Remove existing variable if it exists
        sed -i.bak "/^export $var_name=/d" "$DEPLOYMENT_ENV_FILE"
        # Add new variable
        echo "export $var_name=\"$var_value\"" >> "$DEPLOYMENT_ENV_FILE"
        rm -f "${DEPLOYMENT_ENV_FILE}.bak"
    fi
}

# Source deployment environment
source_deployment_env() {
    if [ -f "$DEPLOYMENT_ENV_FILE" ]; then
        source "$DEPLOYMENT_ENV_FILE"
    fi
}

# Validate required variables
validate_config() {
    local required_vars=(
        "COREBANK_ACCOUNT"
        "SATELLITE_ACCOUNT"
        "AWS_REGION"
    )
    
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var}" ]]; then
            echo "ERROR: Required variable $var is not set"
            exit 1
        fi
    done
}

# Call validation
validate_config

# Initialize deployment environment
init_deployment_env
