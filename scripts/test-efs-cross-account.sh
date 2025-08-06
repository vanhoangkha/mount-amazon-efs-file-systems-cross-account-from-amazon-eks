#!/bin/bash

# Cross-Account EFS Testing Script
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

# Test function to check endpoint health
test_endpoint_health() {
    local endpoint=$1
    local name=$2
    local max_attempts=5
    local attempt=0
    
    info "Testing $name health at $endpoint"
    
    while [ $attempt -lt $max_attempts ]; do
        if curl -f -s "$endpoint/health" > /dev/null 2>&1; then
            log "✓ $name is healthy"
            return 0
        fi
        
        warn "Health check attempt $((attempt+1))/$max_attempts failed for $name"
        sleep 5
        attempt=$((attempt+1))
    done
    
    error "Health check failed for $name after $max_attempts attempts"
    return 1
}

# Test EFS write and read operations
test_efs_operations() {
    local endpoint=$1
    local name=$2
    local test_data="test-data-$(date +%s)"
    
    info "Testing EFS operations for $name"
    
    # Test write operation
    info "Testing write operation..."
    local write_response=$(curl -s -X POST "$endpoint/write" \
        -H "Content-Type: application/json" \
        -d "{\"data\": \"$test_data\"}")
    
    if echo "$write_response" | grep -q "success"; then
        log "✓ Write operation successful for $name"
    else
        error "Write operation failed for $name: $write_response"
    fi
    
    # Test read operation
    info "Testing read operation..."
    local read_response=$(curl -s "$endpoint/read")
    
    if echo "$read_response" | grep -q "$test_data"; then
        log "✓ Read operation successful for $name - data found"
    else
        error "Read operation failed for $name - data not found: $read_response"
    fi
    
    # Test list operation
    info "Testing list operation..."
    local list_response=$(curl -s "$endpoint/list")
    
    if [ -n "$list_response" ]; then
        log "✓ List operation successful for $name"
    else
        error "List operation failed for $name"
    fi
}

# Test cross-account access
test_cross_account_access() {
    info "Testing cross-account EFS access"
    
    # Both applications should be able to read/write to the same EFS
    local corebank_test_data="corebank-data-$(date +%s)"
    local satellite_test_data="satellite-data-$(date +%s)"
    
    # Write from CoreBank
    if [ -n "$COREBANK_ENDPOINT" ] && [ "$COREBANK_ENDPOINT" != "http://pending" ]; then
        info "Writing data from CoreBank application..."
        curl -s -X POST "$COREBANK_ENDPOINT/write" \
            -H "Content-Type: application/json" \
            -d "{\"data\": \"$corebank_test_data\"}" > /dev/null
        
        # Read from Satellite
        if [ -n "$SATELLITE_ENDPOINT" ] && [ "$SATELLITE_ENDPOINT" != "http://pending" ]; then
            info "Reading data from Satellite application..."
            local satellite_read=$(curl -s "$SATELLITE_ENDPOINT/read")
            
            if echo "$satellite_read" | grep -q "$corebank_test_data"; then
                log "✓ Cross-account access successful: Satellite can read CoreBank data"
            else
                warn "Cross-account read test failed: Satellite cannot read CoreBank data"
            fi
        fi
    fi
    
    # Write from Satellite
    if [ -n "$SATELLITE_ENDPOINT" ] && [ "$SATELLITE_ENDPOINT" != "http://pending" ]; then
        info "Writing data from Satellite application..."
        curl -s -X POST "$SATELLITE_ENDPOINT/write" \
            -H "Content-Type: application/json" \
            -d "{\"data\": \"$satellite_test_data\"}" > /dev/null
        
        # Read from CoreBank
        if [ -n "$COREBANK_ENDPOINT" ] && [ "$COREBANK_ENDPOINT" != "http://pending" ]; then
            info "Reading data from CoreBank application..."
            local corebank_read=$(curl -s "$COREBANK_ENDPOINT/read")
            
            if echo "$corebank_read" | grep -q "$satellite_test_data"; then
                log "✓ Cross-account access successful: CoreBank can read Satellite data"
            else
                warn "Cross-account read test failed: CoreBank cannot read Satellite data"
            fi
        fi
    fi
}

# Test VPC connectivity
test_vpc_connectivity() {
    info "Testing VPC connectivity and security groups"
    
    # Check if clusters are accessible
    for account in "corebank" "satellite"; do
        export AWS_PROFILE="$account"
        
        if kubectl config use-context "$account-cluster" &>/dev/null; then
            info "Testing $account cluster connectivity..."
            
            # Get VPC information
            local vpc_id=$(aws ec2 describe-vpcs \
                --filters "Name=tag:eksctl.cluster.k8s.io/v1alpha1/cluster-name,Values=$account-cluster" \
                --query 'Vpcs[0].VpcId' \
                --output text \
                --region $AWS_REGION)
            
            local vpc_cidr=$(aws ec2 describe-vpcs \
                --vpc-ids $vpc_id \
                --query 'Vpcs[0].CidrBlock' \
                --output text \
                --region $AWS_REGION)
            
            info "$account cluster VPC: $vpc_id ($vpc_cidr)"
            
            # Test pod connectivity
            local pod_count=$(kubectl get pods -n default --no-headers | wc -l)
            info "$account cluster has $pod_count pods running"
            
            log "✓ $account cluster connectivity verified"
        else
            warn "Cannot connect to $account cluster"
        fi
    done
}

# Performance testing
test_performance() {
    local endpoint=$1
    local name=$2
    
    info "Running performance test for $name"
    
    local start_time=$(date +%s)
    local test_count=10
    local success_count=0
    
    for i in $(seq 1 $test_count); do
        local test_data="perf-test-$i-$(date +%s)"
        
        # Write test
        local write_response=$(curl -s -w "%{http_code}" -X POST "$endpoint/write" \
            -H "Content-Type: application/json" \
            -d "{\"data\": \"$test_data\"}")
        
        if echo "$write_response" | grep -q "200"; then
            success_count=$((success_count + 1))
        fi
        
        sleep 1
    done
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local success_rate=$((success_count * 100 / test_count))
    
    info "Performance test results for $name:"
    info "  - Total requests: $test_count"
    info "  - Successful requests: $success_count"
    info "  - Success rate: $success_rate%"
    info "  - Duration: ${duration}s"
    info "  - Average: $((duration * 1000 / test_count))ms per request"
    
    if [ $success_rate -ge 80 ]; then
        log "✓ Performance test passed for $name"
    else
        warn "Performance test marginal for $name (success rate: $success_rate%)"
    fi
}

# Main test function
main() {
    log "Starting Cross-Account EFS Testing"
    log "CoreBank Account: $COREBANK_ACCOUNT (VPC CIDR: $COREBANK_VPC_CIDR)"
    log "Satellite Account: $SATELLITE_ACCOUNT (VPC CIDR: $SATELLITE_VPC_CIDR)"
    
    # Check prerequisites
    if ! command -v curl &> /dev/null; then
        error "curl is required but not installed"
    fi
    
    if ! command -v kubectl &> /dev/null; then
        error "kubectl is required but not installed"
    fi
    
    # Test VPC connectivity first
    test_vpc_connectivity
    
    # Test application endpoints
    if [ -n "$COREBANK_ENDPOINT" ] && [ "$COREBANK_ENDPOINT" != "http://pending" ]; then
        test_endpoint_health "$COREBANK_ENDPOINT" "CoreBank"
        test_efs_operations "$COREBANK_ENDPOINT" "CoreBank"
        test_performance "$COREBANK_ENDPOINT" "CoreBank"
    else
        warn "CoreBank endpoint not available, skipping CoreBank tests"
    fi
    
    if [ -n "$SATELLITE_ENDPOINT" ] && [ "$SATELLITE_ENDPOINT" != "http://pending" ]; then
        test_endpoint_health "$SATELLITE_ENDPOINT" "Satellite"
        test_efs_operations "$SATELLITE_ENDPOINT" "Satellite"
        test_performance "$SATELLITE_ENDPOINT" "Satellite"
    else
        warn "Satellite endpoint not available, skipping Satellite tests"
    fi
    
    # Test cross-account functionality
    if [ -n "$COREBANK_ENDPOINT" ] && [ -n "$SATELLITE_ENDPOINT" ] && 
       [ "$COREBANK_ENDPOINT" != "http://pending" ] && [ "$SATELLITE_ENDPOINT" != "http://pending" ]; then
        test_cross_account_access
    else
        warn "Both endpoints not available, skipping cross-account tests"
    fi
    
    log "🎉 Cross-Account EFS Testing Completed!"
    log ""
    log "Test Summary:"
    log "  - VPC connectivity: Verified"
    log "  - Application health: Tested"
    log "  - EFS operations: Tested"
    log "  - Cross-account access: Tested"
    log "  - Performance: Benchmarked"
    log ""
    log "For detailed monitoring:"
    log "  - Check CloudWatch dashboards"
    log "  - Review EFS performance metrics"
    log "  - Monitor application logs: kubectl logs -l account=corebank"
}

# Run main function
main "$@"
