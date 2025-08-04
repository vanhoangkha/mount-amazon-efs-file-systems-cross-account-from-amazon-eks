#!/bin/bash

# Configuration file for cross-account EFS deployment

# AWS Account Configuration
export COREBANK_ACCOUNT="${COREBANK_ACCOUNT:-111111111111}"
export SATELLITE1_ACCOUNT="${SATELLITE1_ACCOUNT:-222222222222}"
export SATELLITE2_ACCOUNT="${SATELLITE2_ACCOUNT:-333333333333}"
export AWS_REGION="${AWS_REGION:-ap-southeast-1}"

# EKS Configuration
export EKS_VERSION="${EKS_VERSION:-1.28}"
export COREBANK_NODE_TYPE="${COREBANK_NODE_TYPE:-c5.xlarge}"
export SATELLITE_NODE_TYPE="${SATELLITE_NODE_TYPE:-c5.large}"

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

# Validate required variables
validate_config() {
    local required_vars=(
        "COREBANK_ACCOUNT"
        "SATELLITE1_ACCOUNT" 
        "SATELLITE2_ACCOUNT"
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
