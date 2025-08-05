#!/bin/bash

# Test EFS Cross-Account Functionality
set -e

# Load configuration
PROJECT_ROOT="."

source "${PROJECT_ROOT}/scripts/config.sh"

# Load application endpoints
if [ -f "${PROJECT_ROOT}/app-endpoints.env" ]; then
    source "${PROJECT_ROOT}/app-endpoints.env"
fi

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

# Test application health
test_health() {
    local endpoint=$1
    local app_name=$2
    
    info "Testing $app_name health..."
    
    local response=$(curl -s -w "%{http_code}" -o /tmp/health_response.json "http://$endpoint/health")
    local http_code="${response: -3}"
    
    if [ "$http_code" = "200" ]; then
        local healthy=$(cat /tmp/health_response.json | python3 -c "import sys, json; print(json.load(sys.stdin)['healthy'])" 2>/dev/null || echo "false")
        if [ "$healthy" = "True" ]; then
            log "✓ $app_name health check passed"
            
            # Show EFS mount status
            local corebank_healthy=$(cat /tmp/health_response.json | python3 -c "import sys, json; print(json.load(sys.stdin)['corebank_efs']['healthy'])" 2>/dev/null || echo "false")
            
            info "$app_name EFS status:"
            info "  - CoreBank EFS: $corebank_healthy"
            
            return 0
        else
            warn "$app_name health check failed - service unhealthy"
            return 1
        fi
    else
        warn "$app_name health check failed - HTTP $http_code"
        return 1
    fi
}

# Test write functionality
test_write() {
    local endpoint=$1
    local app_name=$2
    local test_id=$3
    
    info "Testing $app_name write functionality..."
    
    local filename="test/write_test_${test_id}_$(date +%s).json"
    local content="Write test data from $app_name - $(date)"
    local metadata='{"test_type":"write_test","app":"'$app_name'","test_id":"'$test_id'"}'
    
    local json_payload=$(cat <<EOF
{
    "filename": "$filename",
    "content": "$content",
    "metadata": $metadata
}
EOF
)
    
    local start_time=$(date +%s.%N)
    local response=$(curl -s -w "%{http_code}" -o /tmp/write_response.json \
        -H "Content-Type: application/json" \
        -d "$json_payload" \
        "http://$endpoint/write")
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc)
    local http_code="${response: -3}"
    
    if [ "$http_code" = "200" ]; then
        local success=$(cat /tmp/write_response.json | python3 -c "import sys, json; print(json.load(sys.stdin)['success'])" 2>/dev/null || echo "false")
        local result_success=$(cat /tmp/write_response.json | python3 -c "import sys, json; print(json.load(sys.stdin)['result']['success'])" 2>/dev/null || echo "false")
        
        info "$app_name write results (${duration}s):"
        info "  - Overall: $success"
        info "  - CoreBank EFS: $result_success"
        
        if [ "$success" = "True" ]; then
            log "✓ $app_name write test passed"
            echo "$filename" >> /tmp/test_files_${test_id}.txt
            return 0
        else
            warn "$app_name write test had issues"
            return 1
        fi
    else
        warn "$app_name write test failed - HTTP $http_code"
        return 1
    fi
}

# Test read functionality
test_read() {
    local endpoint=$1
    local app_name=$2
    local filename=$3
    
    info "Testing $app_name read from CoreBank EFS..."
    
    local response=$(curl -s -w "%{http_code}" -o /tmp/read_response.json \
        "http://$endpoint/read?filename=$filename")
    local http_code="${response: -3}"
    
    if [ "$http_code" = "200" ]; then
        local success=$(cat /tmp/read_response.json | python3 -c "import sys, json; print(json.load(sys.stdin)['success'])" 2>/dev/null || echo "false")
        if [ "$success" = "True" ]; then
            log "✓ $app_name read from CoreBank EFS successful"
            return 0
        else
            warn "$app_name read from CoreBank EFS failed"
            return 1
        fi
    else
        warn "$app_name read from CoreBank EFS failed - HTTP $http_code"
        return 1
    fi
}

# Test list functionality
test_list() {
    local endpoint=$1
    local app_name=$2
    
    info "Testing $app_name list files from CoreBank EFS..."
    
    local response=$(curl -s -w "%{http_code}" -o /tmp/list_response.json \
        "http://$endpoint/list?path=test")
    local http_code="${response: -3}"
    
    if [ "$http_code" = "200" ]; then
        local success=$(cat /tmp/list_response.json | python3 -c "import sys, json; print(json.load(sys.stdin)['success'])" 2>/dev/null || echo "false")
        if [ "$success" = "True" ]; then
            local file_count=$(cat /tmp/list_response.json | python3 -c "import sys, json; print(json.load(sys.stdin)['total'])" 2>/dev/null || echo "0")
            log "✓ $app_name list from CoreBank EFS successful ($file_count files)"
            return 0
        else
            warn "$app_name list from CoreBank EFS failed"
            return 1
        fi
    else
        warn "$app_name list from CoreBank EFS failed - HTTP $http_code"
        return 1
    fi
}

# Test automated test suite
test_automated_suite() {
    local endpoint=$1
    local app_name=$2
    
    info "Running $app_name automated test suite..."
    
    local start_time=$(date +%s.%N)
    local response=$(curl -s -w "%{http_code}" -o /tmp/suite_response.json \
        -X POST "http://$endpoint/test")
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc)
    local http_code="${response: -3}"
    
    if [ "$http_code" = "200" ]; then
        local success=$(cat /tmp/suite_response.json | python3 -c "import sys, json; print(json.load(sys.stdin)['success'])" 2>/dev/null || echo "false")
        if [ "$success" = "True" ]; then
            log "✓ $app_name automated test suite passed (${duration}s)"
            return 0
        else
            warn "$app_name automated test suite failed"
            return 1
        fi
    else
        warn "$app_name automated test suite failed - HTTP $http_code"
        return 1
    fi
}

# Test cross-account data consistency
test_cross_account_consistency() {
    info "Testing cross-account data consistency..."
    
    # Write data from satellite
    if [ ! -z "$SATELLITE_ENDPOINT" ] && [ ! -z "$COREBANK_ENDPOINT" ]; then
        local filename="test/consistency_test_$(date +%s).json"
        local content="Cross-account consistency test data"
        
        info "Writing data from Satellite..."
        curl -s -X POST -H "Content-Type: application/json" \
            -d "{\"filename\":\"$filename\",\"content\":\"$content\"}" \
            "http://$SATELLITE_ENDPOINT/write" > /tmp/consistency_write.json
        
        sleep 5  # Wait for sync
        
        # Try to read from CoreBank
        info "Reading data from CoreBank EFS..."
        if test_read "$COREBANK_ENDPOINT" "CoreBank" "$filename"; then
            log "✓ Cross-account data consistency test passed"
            return 0
        else
            warn "Cross-account data consistency test failed"
            return 1
        fi
    fi
    
    warn "Cross-account consistency test skipped - endpoints not available"
    return 1
}

# Performance test
test_performance() {
    local endpoint=$1
    local app_name=$2
    local num_files=${3:-10}
    
    info "Running $app_name performance test ($num_files files)..."
    
    local start_time=$(date +%s.%N)
    local success_count=0
    local fail_count=0
    
    for i in $(seq 1 $num_files); do
        local filename="test/perf_test_${i}_$(date +%s).json"
        local content="Performance test data $i - $(date)"
        
        local response=$(curl -s -w "%{http_code}" -o /dev/null \
            -H "Content-Type: application/json" \
            -d "{\"filename\":\"$filename\",\"content\":\"$content\"}" \
            "http://$endpoint/write")
        
        if [ "${response: -3}" = "200" ]; then
            ((success_count++))
        else
            ((fail_count++))
        fi
    done
    
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc)
    local throughput=$(echo "scale=2; $num_files / $duration" | bc)
    
    info "$app_name performance results:"
    info "  - Duration: ${duration}s"
    info "  - Successful writes: $success_count/$num_files"
    info "  - Failed writes: $fail_count/$num_files"
    info "  - Throughput: $throughput files/sec"
    
    if [ $success_count -eq $num_files ]; then
        log "✓ $app_name performance test passed"
        return 0
    else
        warn "$app_name performance test had failures"
        return 1
    fi
}

# Main test function
main() {
    log "Starting EFS Cross-Account Functionality Tests"
    
    # Check if endpoints are available
    if [ -z "$COREBANK_ENDPOINT" ] && [ -z "$SATELLITE_ENDPOINT" ]; then
        error "No application endpoints found. Deploy applications first with ./scripts/deploy-efs-test-app.sh"
    fi
    
    local test_results=()
    local test_id=$(date +%s)
    
    # Test CoreBank application
    if [ ! -z "$COREBANK_ENDPOINT" ]; then
        log "Testing CoreBank Application ($COREBANK_ENDPOINT)"
        
        test_health "$COREBANK_ENDPOINT" "CoreBank" && test_results+=("CoreBank-Health: PASS") || test_results+=("CoreBank-Health: FAIL")
        test_write "$COREBANK_ENDPOINT" "CoreBank" "$test_id" && test_results+=("CoreBank-Write: PASS") || test_results+=("CoreBank-Write: FAIL")
        test_list "$COREBANK_ENDPOINT" "CoreBank" && test_results+=("CoreBank-List: PASS") || test_results+=("CoreBank-List: FAIL")
        test_automated_suite "$COREBANK_ENDPOINT" "CoreBank" && test_results+=("CoreBank-Suite: PASS") || test_results+=("CoreBank-Suite: FAIL")
        test_performance "$COREBANK_ENDPOINT" "CoreBank" 5 && test_results+=("CoreBank-Performance: PASS") || test_results+=("CoreBank-Performance: FAIL")
    fi
    
    # Test Satellite application
    if [ ! -z "$SATELLITE_ENDPOINT" ]; then
        log "Testing Satellite Application ($SATELLITE_ENDPOINT)"
        
        test_health "$SATELLITE_ENDPOINT" "Satellite" && test_results+=("Satellite-Health: PASS") || test_results+=("Satellite-Health: FAIL")
        test_write "$SATELLITE_ENDPOINT" "Satellite" "$test_id" && test_results+=("Satellite-Write: PASS") || test_results+=("Satellite-Write: FAIL")
        test_list "$SATELLITE_ENDPOINT" "Satellite" && test_results+=("Satellite-List: PASS") || test_results+=("Satellite-List: FAIL")
        test_automated_suite "$SATELLITE_ENDPOINT" "Satellite" && test_results+=("Satellite-Suite: PASS") || test_results+=("Satellite-Suite: FAIL")
        test_performance "$SATELLITE_ENDPOINT" "Satellite" 5 && test_results+=("Satellite-Performance: PASS") || test_results+=("Satellite-Performance: FAIL")
        
        # Test reading from CoreBank mount
        if [ -f /tmp/test_files_${test_id}.txt ]; then
            local test_file=$(head -n1 /tmp/test_files_${test_id}.txt)
            if [ ! -z "$test_file" ]; then
                test_read "$SATELLITE_ENDPOINT" "Satellite" "$test_file" && test_results+=("Satellite-Read: PASS") || test_results+=("Satellite-Read: FAIL")
            fi
        fi
    fi
    
    # Test cross-account consistency
    test_cross_account_consistency && test_results+=("Cross-Account-Consistency: PASS") || test_results+=("Cross-Account-Consistency: FAIL")
    
    # Generate test report
    log "🎉 EFS Cross-Account Testing Completed!"
    log ""
    log "Test Results Summary:"
    log "===================="
    
    local pass_count=0
    local fail_count=0
    
    for result in "${test_results[@]}"; do
        if [[ $result == *"PASS"* ]]; then
            log "✓ $result"
            ((pass_count++))
        else
            warn "✗ $result"
            ((fail_count++))
        fi
    done
    
    log ""
    log "Overall Results:"
    log "  - Passed: $pass_count"
    log "  - Failed: $fail_count"
    log "  - Total: $((pass_count + fail_count))"
    
    if [ $fail_count -eq 0 ]; then
        log "🎉 All tests passed! EFS cross-account functionality is working correctly."
        exit 0
    else
        warn "⚠️  Some tests failed. Please check the logs above for details."
        exit 1
    fi
}

# Check dependencies
command -v curl >/dev/null 2>&1 || error "curl is required but not installed"
command -v python3 >/dev/null 2>&1 || error "python3 is required but not installed"
command -v bc >/dev/null 2>&1 || error "bc is required but not installed"

# Run main function
main "$@"
