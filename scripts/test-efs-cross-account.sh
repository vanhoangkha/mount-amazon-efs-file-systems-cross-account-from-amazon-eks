#!/bin/bash

# Test Cross-Account EFS Functionality
set -e

PROJECT_ROOT="."
source ./scripts/config.sh

# Source endpoints if available
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
}

info() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $1${NC}"
}

success() {
    echo -e "${GREEN}✓ $1${NC}"
}

failure() {
    echo -e "${RED}✗ $1${NC}"
}

# Test results tracking
declare -A test_results
total_tests=0
passed_tests=0

# Record test result
record_test() {
    local test_name=$1
    local result=$2
    local details=$3
    
    total_tests=$((total_tests + 1))
    test_results["$test_name"]="$result|$details"
    
    if [ "$result" = "PASS" ]; then
        passed_tests=$((passed_tests + 1))
        success "$test_name: $details"
    else
        failure "$test_name: $details"
    fi
}

# Test application health
test_health() {
    local app_name=$1
    local endpoint=$2
    
    info "Testing $app_name health at $endpoint"
    
    if [ -z "$endpoint" ] || [ "$endpoint" = "http://pending" ]; then
        record_test "$app_name Health Check" "FAIL" "Endpoint not available"
        return 1
    fi
    
    local response=$(curl -s -w "%{http_code}" -o /tmp/health_response.json "$endpoint/health" 2>/dev/null || echo "000")
    
    if [ "$response" = "200" ]; then
        local status=$(cat /tmp/health_response.json | python3 -c "import json,sys; print(json.load(sys.stdin).get('status', 'unknown'))" 2>/dev/null || echo "unknown")
        if [ "$status" = "healthy" ]; then
            record_test "$app_name Health Check" "PASS" "Application is healthy"
            return 0
        else
            record_test "$app_name Health Check" "FAIL" "Application status: $status"
            return 1
        fi
    else
        record_test "$app_name Health Check" "FAIL" "HTTP $response"
        return 1
    fi
}

# Test file write operation
test_write() {
    local app_name=$1
    local endpoint=$2
    local test_filename="test/cross-account-test-$(date +%s).json"
    
    info "Testing $app_name write operation"
    
    if [ -z "$endpoint" ] || [ "$endpoint" = "http://pending" ]; then
        record_test "$app_name Write Test" "FAIL" "Endpoint not available"
        return 1
    fi
    
    local test_data=$(cat << EOF
{
    "filename": "$test_filename",
    "content": "Test data from $app_name at $(date)",
    "metadata": {
        "test_type": "cross_account",
        "source_app": "$app_name",
        "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
        "test_id": "$(uuidgen 2>/dev/null || echo 'test-$(date +%s)')"
    }
}
EOF
)
    
    local response=$(curl -s -w "%{http_code}" -H "Content-Type: application/json" -d "$test_data" -o /tmp/write_response.json "$endpoint/write" 2>/dev/null || echo "000")
    
    if [ "$response" = "200" ]; then
        local success=$(cat /tmp/write_response.json | python3 -c "import json,sys; print(json.load(sys.stdin).get('success', False))" 2>/dev/null || echo "false")
        if [ "$success" = "True" ]; then
            record_test "$app_name Write Test" "PASS" "File written: $test_filename"
            echo "$test_filename" >> /tmp/test_files_written.txt
            return 0
        else
            local error_msg=$(cat /tmp/write_response.json | python3 -c "import json,sys; print(json.load(sys.stdin).get('error', 'Unknown error'))" 2>/dev/null || echo "Unknown error")
            record_test "$app_name Write Test" "FAIL" "Write failed: $error_msg"
            return 1
        fi
    else
        record_test "$app_name Write Test" "FAIL" "HTTP $response"
        return 1
    fi
}

# Test file read operation
test_read() {
    local app_name=$1
    local endpoint=$2
    local filename=$3
    
    info "Testing $app_name read operation for file: $filename"
    
    if [ -z "$endpoint" ] || [ "$endpoint" = "http://pending" ]; then
        record_test "$app_name Read Test" "FAIL" "Endpoint not available"
        return 1
    fi
    
    local response=$(curl -s -w "%{http_code}" -o /tmp/read_response.json "$endpoint/read?filename=$filename" 2>/dev/null || echo "000")
    
    if [ "$response" = "200" ]; then
        local success=$(cat /tmp/read_response.json | python3 -c "import json,sys; print(json.load(sys.stdin).get('success', False))" 2>/dev/null || echo "false")
        if [ "$success" = "True" ]; then
            record_test "$app_name Read Test" "PASS" "File read successfully: $filename"
            return 0
        else
            local error_msg=$(cat /tmp/read_response.json | python3 -c "import json,sys; print(json.load(sys.stdin).get('error', 'Unknown error'))" 2>/dev/null || echo "Unknown error")
            record_test "$app_name Read Test" "FAIL" "Read failed: $error_msg"
            return 1
        fi
    elif [ "$response" = "404" ]; then
        record_test "$app_name Read Test" "FAIL" "File not found: $filename"
        return 1
    else
        record_test "$app_name Read Test" "FAIL" "HTTP $response"
        return 1
    fi
}

# Test file listing
test_list() {
    local app_name=$1
    local endpoint=$2
    
    info "Testing $app_name file listing"
    
    if [ -z "$endpoint" ] || [ "$endpoint" = "http://pending" ]; then
        record_test "$app_name List Test" "FAIL" "Endpoint not available"
        return 1
    fi
    
    local response=$(curl -s -w "%{http_code}" -o /tmp/list_response.json "$endpoint/list" 2>/dev/null || echo "000")
    
    if [ "$response" = "200" ]; then
        local success=$(cat /tmp/list_response.json | python3 -c "import json,sys; print(json.load(sys.stdin).get('success', False))" 2>/dev/null || echo "false")
        if [ "$success" = "True" ]; then
            local file_count=$(cat /tmp/list_response.json | python3 -c "import json,sys; print(json.load(sys.stdin).get('total_files', 0))" 2>/dev/null || echo "0")
            record_test "$app_name List Test" "PASS" "Listed $file_count files"
            return 0
        else
            local error_msg=$(cat /tmp/list_response.json | python3 -c "import json,sys; print(json.load(sys.stdin).get('error', 'Unknown error'))" 2>/dev/null || echo "Unknown error")
            record_test "$app_name List Test" "FAIL" "List failed: $error_msg"
            return 1
        fi
    else
        record_test "$app_name List Test" "FAIL" "HTTP $response"
        return 1
    fi
}

# Test cross-account data consistency
test_cross_account_consistency() {
    info "Testing cross-account data consistency"
    
    # Initialize test files list
    > /tmp/test_files_written.txt
    
    # Write from CoreBank, read from Satellite
    if test_write "CoreBank" "$COREBANK_ENDPOINT"; then
        local corebank_file=$(tail -n 1 /tmp/test_files_written.txt)
        sleep 5  # Allow time for EFS consistency
        if test_read "Satellite" "$SATELLITE_ENDPOINT" "$corebank_file"; then
            record_test "Cross-Account Consistency (CoreBank->Satellite)" "PASS" "File written by CoreBank successfully read by Satellite"
        fi
    fi
    
    # Write from Satellite, read from CoreBank
    if test_write "Satellite" "$SATELLITE_ENDPOINT"; then
        local satellite_file=$(tail -n 1 /tmp/test_files_written.txt)
        sleep 5  # Allow time for EFS consistency
        if test_read "CoreBank" "$COREBANK_ENDPOINT" "$satellite_file"; then
            record_test "Cross-Account Consistency (Satellite->CoreBank)" "PASS" "File written by Satellite successfully read by CoreBank"
        fi
    fi
}

# Test performance
test_performance() {
    local app_name=$1
    local endpoint=$2
    
    info "Testing $app_name performance"
    
    if [ -z "$endpoint" ] || [ "$endpoint" = "http://pending" ]; then
        record_test "$app_name Performance Test" "FAIL" "Endpoint not available"
        return 1
    fi
    
    # Run automated test suite
    local start_time=$(date +%s.%N)
    local response=$(curl -s -w "%{http_code}" -X POST -o /tmp/perf_response.json "$endpoint/test" 2>/dev/null || echo "000")
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc 2>/dev/null || echo "0")
    
    if [ "$response" = "200" ]; then
        local overall_success=$(cat /tmp/perf_response.json | python3 -c "import json,sys; print(json.load(sys.stdin).get('overall_success', False))" 2>/dev/null || echo "false")
        if [ "$overall_success" = "True" ]; then
            record_test "$app_name Performance Test" "PASS" "Automated tests passed in ${duration}s"
            return 0
        else
            record_test "$app_name Performance Test" "FAIL" "Some automated tests failed in ${duration}s"
            return 1
        fi
    else
        record_test "$app_name Performance Test" "FAIL" "HTTP $response"
        return 1
    fi
}

# Print test summary
print_test_summary() {
    log ""
    log "🧪 Test Results Summary"
    log "======================"
    log "Total Tests: $total_tests"
    log "Passed: $passed_tests"
    log "Failed: $((total_tests - passed_tests))"
    log "Success Rate: $(echo "scale=1; $passed_tests * 100 / $total_tests" | bc 2>/dev/null || echo "0")%"
    log ""
    
    if [ $passed_tests -eq $total_tests ]; then
        log "🎉 All tests passed! Cross-account EFS functionality is working correctly."
    else
        log "⚠️  Some tests failed. Please check the details above."
    fi
    
    # Detailed results
    log ""
    log "Detailed Results:"
    log "=================="
    for test_name in "${!test_results[@]}"; do
        local result=$(echo "${test_results[$test_name]}" | cut -d'|' -f1)
        local details=$(echo "${test_results[$test_name]}" | cut -d'|' -f2-)
        
        if [ "$result" = "PASS" ]; then
            echo -e "${GREEN}✓ $test_name${NC}: $details"
        else
            echo -e "${RED}✗ $test_name${NC}: $details"
        fi
    done
}

# Cleanup function
cleanup() {
    rm -f /tmp/health_response.json
    rm -f /tmp/write_response.json
    rm -f /tmp/read_response.json
    rm -f /tmp/list_response.json
    rm -f /tmp/perf_response.json
    rm -f /tmp/test_files_written.txt
}

# Main function
main() {
    log "Starting Cross-Account EFS Test Suite"
    log "======================================"
    
    # Setup cleanup trap
    trap cleanup EXIT
    
    # Check if endpoints are available
    if [ -z "$COREBANK_ENDPOINT" ] && [ -z "$SATELLITE_ENDPOINT" ]; then
        error "No application endpoints found. Please run deploy-efs-test-app.sh first."
    fi
    
    log "Testing with endpoints:"
    log "  CoreBank: ${COREBANK_ENDPOINT:-Not Available}"
    log "  Satellite: ${SATELLITE_ENDPOINT:-Not Available}"
    log ""
    
    # Run health checks
    log "🔍 Running Health Checks"
    log "========================="
    if [ -n "$COREBANK_ENDPOINT" ]; then
        test_health "CoreBank" "$COREBANK_ENDPOINT"
    fi
    if [ -n "$SATELLITE_ENDPOINT" ]; then
        test_health "Satellite" "$SATELLITE_ENDPOINT"
    fi
    
    # Run basic functionality tests
    log ""
    log "📝 Running Basic Functionality Tests"
    log "====================================="
    
    if [ -n "$COREBANK_ENDPOINT" ]; then
        test_write "CoreBank" "$COREBANK_ENDPOINT"
        test_list "CoreBank" "$COREBANK_ENDPOINT"
    fi
    
    if [ -n "$SATELLITE_ENDPOINT" ]; then
        test_write "Satellite" "$SATELLITE_ENDPOINT"
        test_list "Satellite" "$SATELLITE_ENDPOINT"
    fi
    
    # Run cross-account consistency tests
    if [ -n "$COREBANK_ENDPOINT" ] && [ -n "$SATELLITE_ENDPOINT" ]; then
        log ""
        log "🔄 Running Cross-Account Consistency Tests"
        log "==========================================="
        test_cross_account_consistency
    fi
    
    # Run performance tests
    log ""
    log "⚡ Running Performance Tests"
    log "============================"
    if [ -n "$COREBANK_ENDPOINT" ]; then
        test_performance "CoreBank" "$COREBANK_ENDPOINT"
    fi
    if [ -n "$SATELLITE_ENDPOINT" ]; then
        test_performance "Satellite" "$SATELLITE_ENDPOINT"
    fi
    
    # Print summary
    print_test_summary
    
    # Set exit code based on test results
    if [ $passed_tests -eq $total_tests ]; then
        exit 0
    else
        exit 1
    fi
}

# Run main function
main "$@"
