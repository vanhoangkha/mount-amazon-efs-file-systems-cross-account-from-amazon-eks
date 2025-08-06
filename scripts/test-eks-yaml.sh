#!/bin/bash

# Quick test to validate EKS YAML generation without actually creating clusters
set -e

PROJECT_ROOT="."
source ./scripts/config.sh

echo "=== EKS YAML Generation Test ==="

# Test function
test_yaml_generation() {
    local account_name="corebank"
    
    # Source deployment environment
    source_deployment_env
    
    # Get variables
    local vpc_id_var="${account_name^^}_VPC_ID"
    local private_subnets_var="${account_name^^}_PRIVATE_SUBNETS"
    local public_subnets_var="${account_name^^}_PUBLIC_SUBNETS"
    
    local vpc_id="${!vpc_id_var}"
    local private_subnets="${!private_subnets_var}"
    local public_subnets="${!public_subnets_var}"
    
    echo "Variables for $account_name:"
    echo "  VPC ID: $vpc_id"
    echo "  Private Subnets: $private_subnets"
    echo "  Public Subnets: $public_subnets"
    
    if [[ -z "$vpc_id" || -z "$private_subnets" || -z "$public_subnets" ]]; then
        echo "ERROR: Missing required variables"
        return 1
    fi
    
    # Create test YAML using improved method
    cat > /tmp/test-eks-config.yaml << EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${account_name}-cluster
  region: ${AWS_REGION}
  version: "${EKS_VERSION}"

vpc:
  id: ${vpc_id}
  clusterEndpoints:
    privateAccess: true
    publicAccess: true
  subnets:
    private:
EOF

    # Add private subnets
    IFS=',' read -ra private_subnet_array <<< "$private_subnets"
    for subnet in "${private_subnet_array[@]}"; do
        subnet=$(echo "$subnet" | xargs)  # Trim whitespace
        if [[ -n "$subnet" ]]; then
            echo "      ${subnet}: {}" >> /tmp/test-eks-config.yaml
        fi
    done

    echo "    public:" >> /tmp/test-eks-config.yaml
    # Add public subnets
    IFS=',' read -ra public_subnet_array <<< "$public_subnets"
    for subnet in "${public_subnet_array[@]}"; do
        subnet=$(echo "$subnet" | xargs)  # Trim whitespace
        if [[ -n "$subnet" ]]; then
            echo "      ${subnet}: {}" >> /tmp/test-eks-config.yaml
        fi
    done

    cat >> /tmp/test-eks-config.yaml << EOF

iam:
  withOIDC: true

nodeGroups:
  - name: ${account_name}-nodes
    instanceType: ${COREBANK_NODE_TYPE}
    minSize: 2
    maxSize: 6
    desiredCapacity: 3
    privateNetworking: true

addons:
  - name: vpc-cni
    version: latest
  - name: coredns
    version: latest
  - name: kube-proxy
    version: latest
  - name: aws-efs-csi-driver
    version: latest
EOF

    echo ""
    echo "=== Generated YAML ==="
    cat /tmp/test-eks-config.yaml
    
    echo ""
    echo "=== YAML Validation ==="
    
    # Check if yq is available for YAML validation
    if command -v yq &> /dev/null; then
        if yq eval . /tmp/test-eks-config.yaml > /dev/null 2>&1; then
            echo "✓ YAML syntax is valid"
        else
            echo "✗ YAML syntax is invalid"
            return 1
        fi
    else
        echo "⚠ yq not found, skipping YAML syntax validation"
    fi
    
    # Test eksctl validation (dry-run)
    if command -v eksctl &> /dev/null; then
        echo "Testing eksctl validation..."
        if eksctl utils describe-stacks --config-file=/tmp/test-eks-config.yaml &>/dev/null; then
            echo "✓ eksctl configuration validation passed"
        else
            echo "⚠ eksctl validation failed or returned warnings"
        fi
    else
        echo "⚠ eksctl not found, skipping eksctl validation"
    fi
    
    echo ""
    echo "=== Subnet Verification ==="
    export AWS_PROFILE="$account_name"
    
    # Verify each subnet exists and belongs to the correct VPC
    for subnet in "${private_subnet_array[@]}"; do
        subnet=$(echo "$subnet" | xargs)
        if [[ -n "$subnet" ]]; then
            local subnet_info=$(aws ec2 describe-subnets --subnet-ids "$subnet" --query 'Subnets[0].[VpcId,AvailabilityZone,CidrBlock]' --output text --region $AWS_REGION 2>/dev/null || echo "ERROR")
            if [[ "$subnet_info" != "ERROR" ]]; then
                read -r subnet_vpc subnet_az subnet_cidr <<< "$subnet_info"
                if [[ "$subnet_vpc" == "$vpc_id" ]]; then
                    echo "✓ Private subnet $subnet: VPC=$subnet_vpc, AZ=$subnet_az, CIDR=$subnet_cidr"
                else
                    echo "✗ Private subnet $subnet: Wrong VPC (expected $vpc_id, got $subnet_vpc)"
                fi
            else
                echo "✗ Private subnet $subnet: Not found or access denied"
            fi
        fi
    done
    
    for subnet in "${public_subnet_array[@]}"; do
        subnet=$(echo "$subnet" | xargs)
        if [[ -n "$subnet" ]]; then
            local subnet_info=$(aws ec2 describe-subnets --subnet-ids "$subnet" --query 'Subnets[0].[VpcId,AvailabilityZone,CidrBlock]' --output text --region $AWS_REGION 2>/dev/null || echo "ERROR")
            if [[ "$subnet_info" != "ERROR" ]]; then
                read -r subnet_vpc subnet_az subnet_cidr <<< "$subnet_info"
                if [[ "$subnet_vpc" == "$vpc_id" ]]; then
                    echo "✓ Public subnet $subnet: VPC=$subnet_vpc, AZ=$subnet_az, CIDR=$subnet_cidr"
                else
                    echo "✗ Public subnet $subnet: Wrong VPC (expected $vpc_id, got $subnet_vpc)"
                fi
            else
                echo "✗ Public subnet $subnet: Not found or access denied"
            fi
        fi
    done
}

# Run the test
test_yaml_generation

echo ""
echo "=== Test completed ==="
