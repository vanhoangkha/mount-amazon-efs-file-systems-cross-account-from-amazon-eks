#!/bin/bash

# Final EFS Cross-Account Testing and Validation
set -e

PROJECT_ROOT="."
source ./scripts/config.sh

# Load EFS infrastructure info
if [ -f "${PROJECT_ROOT}/efs-infrastructure.env" ]; then
    source "${PROJECT_ROOT}/efs-infrastructure.env"
fi

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
}

info() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $1${NC}"
}

# Test endpoint with retries
test_endpoint() {
    local endpoint=$1
    local app_name=$2
    local max_attempts=10
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        info "Testing $app_name endpoint (attempt $attempt/$max_attempts)..."
        
        if curl -s -f "http://$endpoint/health" > /tmp/health_$app_name.json; then
            local healthy=$(python3 -c "import sys, json; print(json.load(sys.stdin).get('healthy', False))" < /tmp/health_$app_name.json 2>/dev/null || echo "false")
            
            if [ "$healthy" = "True" ]; then
                log "✓ $app_name is healthy and ready"
                return 0
            fi
        fi
        
        sleep 30
        attempt=$((attempt + 1))
    done
    
    warn "✗ $app_name failed health check after $max_attempts attempts"
    return 1
}

# Test write functionality
test_write() {
    local endpoint=$1
    local app_name=$2
    
    info "Testing $app_name write functionality..."
    
    local test_data=$(cat <<EOF
{
    "filename": "validation/test_${app_name}_$(date +%s).json",
    "content": "Validation test from $app_name at $(date)",
    "metadata": {
        "test_type": "validation",
        "app": "$app_name",
        "timestamp": "$(date -Iseconds)"
    }
}
EOF
)
    
    if curl -s -f -X POST \
        -H "Content-Type: application/json" \
        -d "$test_data" \
        "http://$endpoint/write" > /tmp/write_$app_name.json; then
        
        local success=$(python3 -c "import sys, json; print(json.load(sys.stdin).get('success', False))" < /tmp/write_$app_name.json 2>/dev/null || echo "false")
        
        if [ "$success" = "True" ]; then
            log "✓ $app_name write test passed"
            return 0
        fi
    fi
    
    warn "✗ $app_name write test failed"
    return 1
}

# Test cross-account file sharing
test_cross_account() {
    info "Testing cross-account file sharing..."
    
    if [ -z "$COREBANK_ENDPOINT" ] || [ -z "$SATELLITE_ENDPOINT" ]; then
        warn "Both endpoints required for cross-account testing"
        return 1
    fi
    
    local shared_file="shared/cross_account_$(date +%s).json"
    local test_data=$(cat <<EOF
{
    "filename": "$shared_file",
    "content": "Cross-account validation test at $(date)",
    "metadata": {
        "test_type": "cross_account_validation",
        "writer": "satellite",
        "timestamp": "$(date -Iseconds)"
    }
}
EOF
)
    
    # Write from Satellite
    info "Writing file from Satellite: $shared_file"
    if curl -s -f -X POST \
        -H "Content-Type: application/json" \
        -d "$test_data" \
        "http://$SATELLITE_ENDPOINT/write" > /tmp/cross_write.json; then
        
        local write_success=$(python3 -c "import sys, json; print(json.load(sys.stdin).get('success', False))" < /tmp/cross_write.json 2>/dev/null || echo "false")
        
        if [ "$write_success" = "True" ]; then
            log "✓ Satellite write successful"
            
            # Wait and read from CoreBank
            sleep 5
            info "Reading file from CoreBank: $shared_file"
            
            if curl -s -f "http://$COREBANK_ENDPOINT/read?filename=$shared_file" > /tmp/cross_read.json; then
                local read_success=$(python3 -c "import sys, json; print(json.load(sys.stdin).get('success', False))" < /tmp/cross_read.json 2>/dev/null || echo "false")
                
                if [ "$read_success" = "True" ]; then
                    log "✓ Cross-account file sharing SUCCESSFUL!"
                    return 0
                fi
            fi
        fi
    fi
    
    warn "✗ Cross-account file sharing failed"
    return 1
}

# Main validation function
main() {
    log "🚀 Starting Final EFS Cross-Account Validation"
    
    # Test infrastructure readiness
    if [ -z "$EFS_COREBANK_ID" ]; then
        error "EFS infrastructure not found. Deploy infrastructure first."
    fi
    
    if [ -z "$SATELLITE_ACCESS_POINT" ]; then
        error "Satellite access point not found. Deploy infrastructure first."
    fi
    
    log "Infrastructure Status:"
    log "  ✓ CoreBank EFS: $EFS_COREBANK_ID"
    log "  ✓ Satellite Access Point: $SATELLITE_ACCESS_POINT"
    
    # Test application endpoints
    local corebank_ok=false
    local satellite_ok=false
    
    if [ -n "$COREBANK_ENDPOINT" ]; then
        if test_endpoint "$COREBANK_ENDPOINT" "CoreBank"; then
            corebank_ok=true
            test_write "$COREBANK_ENDPOINT" "CoreBank"
        fi
    else
        warn "CoreBank endpoint not available"
    fi
    
    if [ -n "$SATELLITE_ENDPOINT" ]; then
        if test_endpoint "$SATELLITE_ENDPOINT" "Satellite"; then
            satellite_ok=true
            test_write "$SATELLITE_ENDPOINT" "Satellite"
        fi
    else
        warn "Satellite endpoint not available"
    fi
    
    # Test cross-account functionality
    if [ "$corebank_ok" = true ] && [ "$satellite_ok" = true ]; then
        test_cross_account
    fi
    
    # Final summary
    log ""
    log "🎉 VALIDATION COMPLETED!"
    log ""
    log "Results Summary:"
    log "  CoreBank App: $([ "$corebank_ok" = true ] && echo "✅ WORKING" || echo "❌ FAILED")"
    log "  Satellite App: $([ "$satellite_ok" = true ] && echo "✅ WORKING" || echo "❌ FAILED")"
    log "  Cross-Account Sharing: $([ "$corebank_ok" = true ] && [ "$satellite_ok" = true ] && echo "✅ TESTED" || echo "⚠️  SKIPPED")"
    log ""
    log "Application Endpoints:"
    log "  CoreBank: ${COREBANK_ENDPOINT:-NOT_AVAILABLE}"
    log "  Satellite: ${SATELLITE_ENDPOINT:-NOT_AVAILABLE}"
    log ""
    log "Test Commands:"
    log "  curl http://\$ENDPOINT/health"
    log "  curl -X POST -H 'Content-Type: application/json' -d '{\"filename\":\"test.json\",\"content\":\"test\"}' http://\$ENDPOINT/write"
    log "  curl 'http://\$ENDPOINT/read?filename=test.json'"
    log "  curl 'http://\$ENDPOINT/list'"
    log "  curl -X POST http://\$ENDPOINT/test"
}

# Run main function
main "$@"
