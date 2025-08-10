#!/bin/bash

# Deploy VPC Infrastructure for EFS Testing
set -e

PROJECT_ROOT="."
source ./scripts/config.sh

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

# Deploy VPC using CloudFormation
deploy_vpc() {
    local account_id=$1
    local account_name=$2
    local vpc_cidr=$3
    
    log "Deploying VPC for $account_name account with CIDR: $vpc_cidr"
    
    # Switch to account
    export AWS_PROFILE="$account_name"
    
    # Check if VPC already exists
    local existing_vpc=$(aws ec2 describe-vpcs \
        --filters "Name=tag:Name,Values=$account_name-vpc" \
        --query 'Vpcs[0].VpcId' \
        --output text \
        --region $AWS_REGION 2>/dev/null || echo "None")
    
    if [ "$existing_vpc" != "None" ] && [ "$existing_vpc" != "null" ]; then
        warn "VPC $account_name-vpc already exists with ID: $existing_vpc, skipping creation"
        update_deployment_env "${account_name^^}_VPC_ID" "$existing_vpc"
        return 0
    fi
    
    # Create CloudFormation template for VPC
    info "Creating VPC CloudFormation template for $account_name"
    cat > /tmp/$account_name-vpc.yaml << EOF
AWSTemplateFormatVersion: '2010-09-09'
Description: 'VPC Infrastructure for $account_name EFS Testing'

Parameters:
  VpcCidr:
    Type: String
    Default: '$vpc_cidr'
    Description: CIDR block for the VPC
  
  AccountName:
    Type: String
    Default: '$account_name'
    Description: Account name for resource tagging

Resources:
  # VPC
  VPC:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: !Ref VpcCidr
      EnableDnsHostnames: true
      EnableDnsSupport: true
      Tags:
        - Key: Name
          Value: !Sub '\${AccountName}-vpc'
        - Key: Environment
          Value: test
        - Key: Service
          Value: !Ref AccountName
        - Key: Purpose
          Value: efs-testing

  # Internet Gateway
  InternetGateway:
    Type: AWS::EC2::InternetGateway
    Properties:
      Tags:
        - Key: Name
          Value: !Sub '\${AccountName}-igw'
        - Key: Environment
          Value: test

  # Attach Internet Gateway to VPC
  InternetGatewayAttachment:
    Type: AWS::EC2::VPCGatewayAttachment
    Properties:
      InternetGatewayId: !Ref InternetGateway
      VpcId: !Ref VPC

  # Public Subnets
  PublicSubnetAZ1:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref VPC
      AvailabilityZone: !Sub '\${AWS::Region}a'
      CidrBlock: !Sub 
        - '\${NetworkPrefix}.100.0/24'
        - NetworkPrefix: !Select [0, !Split ['.0.0/', !Ref VpcCidr]]
      MapPublicIpOnLaunch: true
      Tags:
        - Key: Name
          Value: !Sub '\${AccountName}-public-subnet-\${AWS::Region}a'
        - Key: Type
          Value: public
        - Key: Environment
          Value: test

  PublicSubnetAZ2:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref VPC
      AvailabilityZone: !Sub '\${AWS::Region}b'
      CidrBlock: !Sub 
        - '\${NetworkPrefix}.101.0/24'
        - NetworkPrefix: !Select [0, !Split ['.0.0/', !Ref VpcCidr]]
      MapPublicIpOnLaunch: true
      Tags:
        - Key: Name
          Value: !Sub '\${AccountName}-public-subnet-\${AWS::Region}b'
        - Key: Type
          Value: public
        - Key: Environment
          Value: test

  PublicSubnetAZ3:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref VPC
      AvailabilityZone: !Sub '\${AWS::Region}c'
      CidrBlock: !Sub 
        - '\${NetworkPrefix}.102.0/24'
        - NetworkPrefix: !Select [0, !Split ['.0.0/', !Ref VpcCidr]]
      MapPublicIpOnLaunch: true
      Tags:
        - Key: Name
          Value: !Sub '\${AccountName}-public-subnet-\${AWS::Region}c'
        - Key: Type
          Value: public
        - Key: Environment
          Value: test

  # Private Subnets
  PrivateSubnetAZ1:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref VPC
      AvailabilityZone: !Sub '\${AWS::Region}a'
      CidrBlock: !Sub 
        - '\${NetworkPrefix}.0.0/24'
        - NetworkPrefix: !Select [0, !Split ['.0.0/', !Ref VpcCidr]]
      Tags:
        - Key: Name
          Value: !Sub '\${AccountName}-private-subnet-\${AWS::Region}a'
        - Key: Type
          Value: private
        - Key: Environment
          Value: test

  PrivateSubnetAZ2:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref VPC
      AvailabilityZone: !Sub '\${AWS::Region}b'
      CidrBlock: !Sub 
        - '\${NetworkPrefix}.1.0/24'
        - NetworkPrefix: !Select [0, !Split ['.0.0/', !Ref VpcCidr]]
      Tags:
        - Key: Name
          Value: !Sub '\${AccountName}-private-subnet-\${AWS::Region}b'
        - Key: Type
          Value: private
        - Key: Environment
          Value: test

  PrivateSubnetAZ3:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref VPC
      AvailabilityZone: !Sub '\${AWS::Region}c'
      CidrBlock: !Sub 
        - '\${NetworkPrefix}.2.0/24'
        - NetworkPrefix: !Select [0, !Split ['.0.0/', !Ref VpcCidr]]
      Tags:
        - Key: Name
          Value: !Sub '\${AccountName}-private-subnet-\${AWS::Region}c'
        - Key: Type
          Value: private
        - Key: Environment
          Value: test

  # NAT Gateways
  NatGateway1EIP:
    Type: AWS::EC2::EIP
    DependsOn: InternetGatewayAttachment
    Properties:
      Domain: vpc
      Tags:
        - Key: Name
          Value: !Sub '\${AccountName}-nat-eip-1'

  NatGateway2EIP:
    Type: AWS::EC2::EIP
    DependsOn: InternetGatewayAttachment
    Properties:
      Domain: vpc
      Tags:
        - Key: Name
          Value: !Sub '\${AccountName}-nat-eip-2'

  NatGateway1:
    Type: AWS::EC2::NatGateway
    Properties:
      AllocationId: !GetAtt NatGateway1EIP.AllocationId
      SubnetId: !Ref PublicSubnetAZ1
      Tags:
        - Key: Name
          Value: !Sub '\${AccountName}-nat-gw-1'

  NatGateway2:
    Type: AWS::EC2::NatGateway
    Properties:
      AllocationId: !GetAtt NatGateway2EIP.AllocationId
      SubnetId: !Ref PublicSubnetAZ2
      Tags:
        - Key: Name
          Value: !Sub '\${AccountName}-nat-gw-2'

  # Route Tables
  PublicRouteTable:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref VPC
      Tags:
        - Key: Name
          Value: !Sub '\${AccountName}-public-rt'
        - Key: Environment
          Value: test

  DefaultPublicRoute:
    Type: AWS::EC2::Route
    DependsOn: InternetGatewayAttachment
    Properties:
      RouteTableId: !Ref PublicRouteTable
      DestinationCidrBlock: 0.0.0.0/0
      GatewayId: !Ref InternetGateway

  PublicSubnet1RouteTableAssociation:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      RouteTableId: !Ref PublicRouteTable
      SubnetId: !Ref PublicSubnetAZ1

  PublicSubnet2RouteTableAssociation:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      RouteTableId: !Ref PublicRouteTable
      SubnetId: !Ref PublicSubnetAZ2

  PublicSubnet3RouteTableAssociation:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      RouteTableId: !Ref PublicRouteTable
      SubnetId: !Ref PublicSubnetAZ3

  PrivateRouteTable1:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref VPC
      Tags:
        - Key: Name
          Value: !Sub '\${AccountName}-private-rt-1'
        - Key: Environment
          Value: test

  DefaultPrivateRoute1:
    Type: AWS::EC2::Route
    Properties:
      RouteTableId: !Ref PrivateRouteTable1
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId: !Ref NatGateway1

  PrivateSubnet1RouteTableAssociation:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      RouteTableId: !Ref PrivateRouteTable1
      SubnetId: !Ref PrivateSubnetAZ1

  PrivateRouteTable2:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref VPC
      Tags:
        - Key: Name
          Value: !Sub '\${AccountName}-private-rt-2'
        - Key: Environment
          Value: test

  DefaultPrivateRoute2:
    Type: AWS::EC2::Route
    Properties:
      RouteTableId: !Ref PrivateRouteTable2
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId: !Ref NatGateway2

  PrivateSubnet2RouteTableAssociation:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      RouteTableId: !Ref PrivateRouteTable2
      SubnetId: !Ref PrivateSubnetAZ2

  PrivateSubnet3RouteTableAssociation:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      RouteTableId: !Ref PrivateRouteTable1
      SubnetId: !Ref PrivateSubnetAZ3

Outputs:
  VpcId:
    Description: VPC ID
    Value: !Ref VPC
    Export:
      Name: !Sub '\${AccountName}-vpc-id'
  
  VpcCidr:
    Description: VPC CIDR
    Value: !Ref VpcCidr
    Export:
      Name: !Sub '\${AccountName}-vpc-cidr'
  
  PublicSubnet1Id:
    Description: Public Subnet 1 ID
    Value: !Ref PublicSubnetAZ1
    Export:
      Name: !Sub '\${AccountName}-public-subnet-1-id'
  
  PublicSubnet2Id:
    Description: Public Subnet 2 ID
    Value: !Ref PublicSubnetAZ2
    Export:
      Name: !Sub '\${AccountName}-public-subnet-2-id'
  
  PublicSubnet3Id:
    Description: Public Subnet 3 ID
    Value: !Ref PublicSubnetAZ3
    Export:
      Name: !Sub '\${AccountName}-public-subnet-3-id'
  
  PrivateSubnet1Id:
    Description: Private Subnet 1 ID
    Value: !Ref PrivateSubnetAZ1
    Export:
      Name: !Sub '\${AccountName}-private-subnet-1-id'
  
  PrivateSubnet2Id:
    Description: Private Subnet 2 ID
    Value: !Ref PrivateSubnetAZ2
    Export:
      Name: !Sub '\${AccountName}-private-subnet-2-id'
  
  PrivateSubnet3Id:
    Description: Private Subnet 3 ID
    Value: !Ref PrivateSubnetAZ3
    Export:
      Name: !Sub '\${AccountName}-private-subnet-3-id'
EOF
    
    # Deploy VPC stack
    info "Deploying VPC CloudFormation stack for $account_name (this may take 5-10 minutes)"
    aws cloudformation create-stack \
        --stack-name "$account_name-vpc" \
        --template-body file:///tmp/$account_name-vpc.yaml \
        --parameters ParameterKey=VpcCidr,ParameterValue=$vpc_cidr \
                     ParameterKey=AccountName,ParameterValue=$account_name \
        --region $AWS_REGION
    
    # Wait for stack creation to complete
    info "Waiting for VPC stack creation to complete..."
    aws cloudformation wait stack-create-complete \
        --stack-name "$account_name-vpc" \
        --region $AWS_REGION
    
    # Get VPC ID and store in deployment environment
    local vpc_id=$(aws cloudformation describe-stacks \
        --stack-name "$account_name-vpc" \
        --region $AWS_REGION \
        --query 'Stacks[0].Outputs[?OutputKey==`VpcId`].OutputValue' \
        --output text)
    
    update_deployment_env "${account_name^^}_VPC_ID" "$vpc_id"
    
    # Display VPC information
    info "VPC $account_name-vpc created successfully"
    info "VPC ID: $vpc_id"
    info "VPC CIDR: $vpc_cidr"
    
    # Get subnet information
    info "Getting subnet information for $account_name-vpc"
    local private_subnets=$(aws cloudformation describe-stacks \
        --stack-name "$account_name-vpc" \
        --region $AWS_REGION \
        --query 'Stacks[0].Outputs[?starts_with(OutputKey, `PrivateSubnet`) && ends_with(OutputKey, `Id`)].OutputValue' \
        --output text | tr '\t' ',')
    
    local public_subnets=$(aws cloudformation describe-stacks \
        --stack-name "$account_name-vpc" \
        --region $AWS_REGION \
        --query 'Stacks[0].Outputs[?starts_with(OutputKey, `PublicSubnet`) && ends_with(OutputKey, `Id`)].OutputValue' \
        --output text | tr '\t' ',')
    
    update_deployment_env "${account_name^^}_PRIVATE_SUBNETS" "$private_subnets"
    update_deployment_env "${account_name^^}_PUBLIC_SUBNETS" "$public_subnets"
    
    info "Private Subnets: $private_subnets"
    info "Public Subnets: $public_subnets"
    
    log "✓ VPC $account_name-vpc deployed successfully"
}

# Main function
main() {
    log "Starting VPC Infrastructure Deployment"
    
    # Display VPC configuration
    info "VPC Configuration:"
    info "  CoreBank VPC CIDR: $COREBANK_VPC_CIDR"
    info "  Satellite VPC CIDR: $SATELLITE_VPC_CIDR"
    
    # Check prerequisites
    if ! command -v aws &> /dev/null; then
        error "aws CLI is required but not installed"
    fi
    
    # Deploy CoreBank VPC
    deploy_vpc "$COREBANK_ACCOUNT" "corebank" "$COREBANK_VPC_CIDR"
    
    # Deploy Satellite VPC
    deploy_vpc "$SATELLITE_ACCOUNT" "satellite" "$SATELLITE_VPC_CIDR"
    
    log "🎉 VPC Infrastructure deployment completed successfully!"
    log ""
    log "VPCs created:"
    log "  CoreBank: corebank-vpc (VPC CIDR: $COREBANK_VPC_CIDR)"
    log "  Satellite: satellite-vpc (VPC CIDR: $SATELLITE_VPC_CIDR)"
    log ""
    log "Next steps:"
    log "1. Deploy EKS clusters: ./scripts/deploy-eks-clusters.sh"
    log "2. Deploy EFS infrastructure: ./scripts/deploy-efs-infrastructure.sh"
    log "3. Build and push images: ./scripts/build-and-push-image.sh"
    log "4. Deploy applications: ./scripts/deploy-efs-test-app.sh"
}

# Run main function
main "$@"
