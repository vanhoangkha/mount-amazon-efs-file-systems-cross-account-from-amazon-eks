#!/bin/bash

# Test script to debug the subnet parsing issue
set -e

PROJECT_ROOT="."
source ./scripts/config.sh

# Test function to debug subnet parsing
test_subnet_parsing() {
    local account_name="corebank"
    
    echo "=== Testing Subnet Parsing for $account_name ==="
    
    # Source deployment environment
    source_deployment_env
    
    # Get variables
    local vpc_id_var="${account_name^^}_VPC_ID"
    local private_subnets_var="${account_name^^}_PRIVATE_SUBNETS"
    local public_subnets_var="${account_name^^}_PUBLIC_SUBNETS"
    
    echo "Variable names:"
    echo "  vpc_id_var: $vpc_id_var"
    echo "  private_subnets_var: $private_subnets_var"
    echo "  public_subnets_var: $public_subnets_var"
    
    # Get values
    local vpc_id="${!vpc_id_var}"
    local private_subnets="${!private_subnets_var}"
    local public_subnets="${!public_subnets_var}"
    
    echo ""
    echo "Raw values:"
    echo "  vpc_id: '$vpc_id'"
    echo "  private_subnets: '$private_subnets'"
    echo "  public_subnets: '$public_subnets'"
    
    echo ""
    echo "String lengths:"
    echo "  vpc_id length: ${#vpc_id}"
    echo "  private_subnets length: ${#private_subnets}"
    echo "  public_subnets length: ${#public_subnets}"
    
    # Test array conversion
    IFS=',' read -ra private_subnet_array <<< "$private_subnets"
    IFS=',' read -ra public_subnet_array <<< "$public_subnets"
    
    echo ""
    echo "Array parsing:"
    echo "  private_subnet_array count: ${#private_subnet_array[@]}"
    echo "  public_subnet_array count: ${#public_subnet_array[@]}"
    
    echo ""
    echo "Array contents:"
    for i in "${!private_subnet_array[@]}"; do
        echo "  private_subnet_array[$i]: '${private_subnet_array[$i]}'"
    done
    
    for i in "${!public_subnet_array[@]}"; do
        echo "  public_subnet_array[$i]: '${public_subnet_array[$i]}'"
    done
    
    echo ""
    echo "=== Testing YAML Generation ==="
    
    # Create a test YAML file
    cat > /tmp/test-cluster.yaml << EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: test-cluster
  region: $AWS_REGION

vpc:
  id: $vpc_id
  subnets:
EOF

    # Add private subnets
    if [[ ${#private_subnet_array[@]} -gt 0 ]]; then
        echo "    private:" >> /tmp/test-cluster.yaml
        for subnet in "${private_subnet_array[@]}"; do
            echo "      $subnet: { }" >> /tmp/test-cluster.yaml
        done
    fi

    # Add public subnets  
    if [[ ${#public_subnet_array[@]} -gt 0 ]]; then
        echo "    public:" >> /tmp/test-cluster.yaml
        for subnet in "${public_subnet_array[@]}"; do
            echo "      $subnet: { }" >> /tmp/test-cluster.yaml
        done
    fi
    
    echo "Generated test YAML:"
    cat /tmp/test-cluster.yaml
    
    echo ""
    echo "=== Testing eksctl validation ==="
    if command -v eksctl &> /dev/null; then
        echo "Validating YAML with eksctl..."
        eksctl utils describe-stacks --config-file=/tmp/test-cluster.yaml || echo "Validation failed"
    else
        echo "eksctl not found, skipping validation"
    fi
}

# Run test
test_subnet_parsing

echo ""
echo "=== Environment Check ==="
echo "Current AWS_PROFILE: ${AWS_PROFILE:-'NOT SET'}"
echo "Current AWS_REGION: ${AWS_REGION:-'NOT SET'}"
echo "Deployment env file: ${DEPLOYMENT_ENV_FILE:-'NOT SET'}"

if [[ -f "${DEPLOYMENT_ENV_FILE}" ]]; then
    echo ""
    echo "=== Deployment Environment File Contents ==="
    cat "${DEPLOYMENT_ENV_FILE}"
else
    echo "Deployment environment file not found!"
fi
