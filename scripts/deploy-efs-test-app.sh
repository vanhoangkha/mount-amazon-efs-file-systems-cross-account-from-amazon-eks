#!/bin/bash

# Deploy EFS Test Application to EKS Clusters
set -e

# Load configuration
PROJECT_ROOT="."

source "${PROJECT_ROOT}/scripts/config.sh"

# Load EFS infrastructure info
if [ -f "${PROJECT_ROOT}/efs-infrastructure.env" ]; then
    source "${PROJECT_ROOT}/efs-infrastructure.env"
fi

# Load ECR URIs
if [ -f "${PROJECT_ROOT}/ecr-uris.env" ]; then
    source "${PROJECT_ROOT}/ecr-uris.env"
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

# Deploy to CoreBank cluster
deploy_to_corebank() {
    log "Deploying EFS Test App to CoreBank cluster..."
    
    # Switch to CoreBank account and update kubeconfig
    export AWS_PROFILE="corebank"
    aws eks update-kubeconfig --region $AWS_REGION --name corebank-cluster --alias corebank-cluster
    
    # Create temporary manifest with substituted values
    info "Creating CoreBank deployment manifest"
    cat "${PROJECT_ROOT}/infrastructure/kubernetes/efs-test-app.yaml" | \
    sed "s/\${EFS_LOCAL_ID}/fs-dummy-local/g" | \
    sed "s/\${EFS_COREBANK_ID}/$EFS_COREBANK_ID/g" | \
    sed "s/\${EFS_ACCESS_POINT_ID}//g" | \
    sed "s/\${ECR_REPOSITORY_URI}/${COREBANK_ECR_URI//\//\\/}/g" | \
    sed "s/\${EFS_CROSS_ACCOUNT_ROLE_ARN}/arn:aws:iam::$COREBANK_ACCOUNT:role\/EKSServiceRole/g" \
    > /tmp/corebank-efs-test-app.yaml
    
    # Apply manifest
    info "Applying CoreBank deployment"
    kubectl apply -f /tmp/corebank-efs-test-app.yaml --context corebank-cluster
    
    # Wait for deployment
    info "Waiting for CoreBank deployment to be ready"
    kubectl wait --for=condition=available --timeout=300s deployment/efs-test-app -n efs-test --context corebank-cluster
    
    # Get service endpoint
    COREBANK_ENDPOINT=$(kubectl get service efs-test-service -n efs-test --context corebank-cluster -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    
    if [ -z "$COREBANK_ENDPOINT" ]; then
        COREBANK_ENDPOINT=$(kubectl get service efs-test-service -n efs-test --context corebank-cluster -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    fi
    
    log "✓ CoreBank deployment completed"
    info "CoreBank endpoint: $COREBANK_ENDPOINT"
    
    echo "COREBANK_ENDPOINT=$COREBANK_ENDPOINT" >> "${PROJECT_ROOT}/app-endpoints.env"
}

# Deploy to Satellite cluster
deploy_to_satellite() {
    local account_id=$1
    local account_name=$2
    local ecr_uri=$3
    local access_point_id=$4
    local local_efs_id=$5
    
    log "Deploying EFS Test App to $account_name cluster..."
    
    # Switch to satellite account and update kubeconfig
    export AWS_PROFILE="$account_name"
    aws eks update-kubeconfig --region $AWS_REGION --name "$account_name-cluster" --alias "$account_name-cluster"
    
    # Create cross-account IAM role for EFS access
    info "Creating cross-account IAM role for $account_name"
    
    # Create trust policy
    cat > /tmp/$account_name-trust-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "arn:aws:iam::$account_id:oidc-provider/$(aws eks describe-cluster --name $account_name-cluster --region $AWS_REGION --query 'cluster.identity.oidc.issuer' --output text | sed 's|https://||')"
            },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
                "StringEquals": {
                    "$(aws eks describe-cluster --name $account_name-cluster --region $AWS_REGION --query 'cluster.identity.oidc.issuer' --output text | sed 's|https://||'):sub": "system:serviceaccount:efs-test:efs-test-sa",
                    "$(aws eks describe-cluster --name $account_name-cluster --region $AWS_REGION --query 'cluster.identity.oidc.issuer' --output text | sed 's|https://||'):aud": "sts.amazonaws.com"
                }
            }
        }
    ]
}
EOF
    
    # Create IAM role
    ROLE_ARN=$(aws iam create-role \
        --role-name "$account_name-EFS-CrossAccount-Role" \
        --assume-role-policy-document file:///tmp/$account_name-trust-policy.json \
        --region $AWS_REGION \
        --query 'Role.Arn' \
        --output text 2>/dev/null || \
    aws iam get-role \
        --role-name "$account_name-EFS-CrossAccount-Role" \
        --query 'Role.Arn' \
        --output text)
    
    # Create policy for EFS access
    cat > /tmp/$account_name-efs-policy.json << EOF
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
    
    # Attach policy to role
    aws iam put-role-policy \
        --role-name "$account_name-EFS-CrossAccount-Role" \
        --policy-name "EFS-Access-Policy" \
        --policy-document file:///tmp/$account_name-efs-policy.json \
        --region $AWS_REGION
    
    # Create temporary manifest with substituted values
    info "Creating $account_name deployment manifest"
    cat "${PROJECT_ROOT}/infrastructure/kubernetes/efs-test-app.yaml" | \
    sed "s/\${EFS_LOCAL_ID}/$local_efs_id/g" | \
    sed "s/\${EFS_COREBANK_ID}/$EFS_COREBANK_ID/g" | \
    sed "s/\${EFS_ACCESS_POINT_ID}/$access_point_id/g" | \
    sed "s/\${ECR_REPOSITORY_URI}/${ecr_uri//\//\\/}/g" | \
    sed "s/\${EFS_CROSS_ACCOUNT_ROLE_ARN}/${ROLE_ARN//\//\\/}/g" \
    > /tmp/$account_name-efs-test-app.yaml
    
    # Apply manifest
    info "Applying $account_name deployment"
    kubectl apply -f /tmp/$account_name-efs-test-app.yaml --context "$account_name-cluster"
    
    # Wait for deployment
    info "Waiting for $account_name deployment to be ready"
    kubectl wait --for=condition=available --timeout=300s deployment/efs-test-app -n efs-test --context "$account_name-cluster"
    
    # Get service endpoint
    SATELLITE_ENDPOINT=$(kubectl get service efs-test-service -n efs-test --context "$account_name-cluster" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    
    if [ -z "$SATELLITE_ENDPOINT" ]; then
        SATELLITE_ENDPOINT=$(kubectl get service efs-test-service -n efs-test --context "$account_name-cluster" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    fi
    
    log "✓ $account_name deployment completed"
    info "$account_name endpoint: $SATELLITE_ENDPOINT"
    
    echo "${account_name^^}_ENDPOINT=$SATELLITE_ENDPOINT" >> "${PROJECT_ROOT}/app-endpoints.env"
}

# Test EFS functionality
test_efs_functionality() {
    log "Testing EFS functionality..."
    
    # Load endpoints
    source "${PROJECT_ROOT}/app-endpoints.env"
    
    # Test CoreBank app
    if [ ! -z "$COREBANK_ENDPOINT" ]; then
        info "Testing CoreBank app health"
        curl -f "http://$COREBANK_ENDPOINT/health" || warn "CoreBank health check failed"
        
        info "Running CoreBank EFS test"
        curl -X POST -H "Content-Type: application/json" \
            -d '{"filename":"test/corebank-test.json","content":"CoreBank test data","metadata":{"source":"corebank"}}' \
            "http://$COREBANK_ENDPOINT/write" || warn "CoreBank write test failed"
    fi
    
    # Test Satellite apps
    for account in "SATELLITE-1" "SATELLITE-2"; do
        endpoint_var="${account//-/_}_ENDPOINT"
        endpoint=${!endpoint_var}
        
        if [ ! -z "$endpoint" ]; then
            info "Testing $account app health"
            curl -f "http://$endpoint/health" || warn "$account health check failed"
            
            info "Running $account EFS test"
            curl -X POST -H "Content-Type: application/json" \
                -d "{\"filename\":\"test/$account-test.json\",\"content\":\"$account test data\",\"metadata\":{\"source\":\"$account\"}}" \
                "http://$endpoint/write" || warn "$account write test failed"
            
            info "Running $account automated test suite"
            curl -X POST "http://$endpoint/test" || warn "$account test suite failed"
        fi
    done
    
    log "✓ EFS functionality testing completed"
}

# Main function
main() {
    log "Starting EFS Test Application Deployment"
    
    # Check prerequisites
    if [ -z "$EFS_COREBANK_ID" ]; then
        error "EFS infrastructure not found. Run ./scripts/deploy-efs-infrastructure.sh first"
    fi
    
    if [ -z "$COREBANK_ECR_URI" ]; then
        error "ECR URIs not found. Run ./scripts/build-and-push-image.sh first"
    fi
    
    # Initialize endpoints file
    echo "# Application endpoints" > "${PROJECT_ROOT}/app-endpoints.env"
    
    # Deploy to CoreBank
    deploy_to_corebank
    
    # Deploy to Satellites
    deploy_to_satellite "$SATELLITE1_ACCOUNT" "satellite-1" "$SATELLITE1_ECR_URI" "$SATELLITE1_ACCESS_POINT" "dummy-local-efs"
    deploy_to_satellite "$SATELLITE2_ACCOUNT" "satellite-2" "$SATELLITE2_ECR_URI" "$SATELLITE2_ACCESS_POINT" "dummy-local-efs"
    
    # Wait for load balancers to be ready
    info "Waiting for load balancers to be ready..."
    sleep 60
    
    # Test functionality
    test_efs_functionality
    
    log "🎉 EFS Test Application deployment completed successfully!"
    log ""
    log "Application endpoints:"
    cat "${PROJECT_ROOT}/app-endpoints.env" | grep -v "^#"
    log ""
    log "Test commands:"
    log "  Health check: curl http://\$ENDPOINT/health"
    log "  Write test: curl -X POST -H 'Content-Type: application/json' -d '{\"filename\":\"test.json\",\"content\":\"test data\"}' http://\$ENDPOINT/write"
    log "  Read test: curl 'http://\$ENDPOINT/read?filename=test.json'"
    log "  List files: curl 'http://\$ENDPOINT/list'"
    log "  Run test suite: curl -X POST http://\$ENDPOINT/test"
}

# Run main function
main "$@"
