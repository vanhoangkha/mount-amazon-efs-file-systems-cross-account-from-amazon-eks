# Network Design

## Overview

This document details the network architecture for the cross-account EFS solution, focusing on secure connectivity between AWS accounts while maintaining performance and compliance requirements.

## Network Architecture Diagram

![Network Architecture](../../architecture/diagrams/banking-network-cross-account.png)

*Figure 1: Complete network topology showing VPC peering, subnet design, and security group configurations*

## VPC Design Principles

### 1. Account Isolation
- Each AWS account has its own VPC for security isolation
- No direct internet connectivity between accounts
- All cross-account communication through VPC peering

### 2. Multi-Tier Architecture
- **Public Tier**: Load balancers and NAT gateways
- **Application Tier**: EKS nodes and application workloads
- **Data Tier**: Databases and storage systems
- **Management Tier**: EFS mount targets and management services

### 3. High Availability
- Resources distributed across 3 Availability Zones
- Redundant NAT gateways in each AZ
- Multi-AZ database deployments

## VPC Specifications

### CoreBank VPC (10.0.0.0/16)

```yaml
VPC Configuration:
  CIDR: 10.0.0.0/16
  Region: ap-southeast-1
  Availability Zones: [1a, 1b, 1c]
  DNS Hostnames: Enabled
  DNS Resolution: Enabled

Subnet Design:
  Public Subnets (Internet Gateway):
    - CoreBank-Public-1A: 10.0.1.0/24 (AZ-1a)
    - CoreBank-Public-1B: 10.0.2.0/24 (AZ-1b)
    - CoreBank-Public-1C: 10.0.3.0/24 (AZ-1c)
    Resources: ALB, NAT Gateways, Bastion Hosts

  Private Application Subnets:
    - CoreBank-App-1A: 10.0.11.0/24 (AZ-1a)
    - CoreBank-App-1B: 10.0.12.0/24 (AZ-1b)
    - CoreBank-App-1C: 10.0.13.0/24 (AZ-1c)
    Resources: EKS Worker Nodes, Application Pods

  Private Database Subnets:
    - CoreBank-DB-1A: 10.0.21.0/24 (AZ-1a)
    - CoreBank-DB-1B: 10.0.22.0/24 (AZ-1b)
    - CoreBank-DB-1C: 10.0.23.0/24 (AZ-1c)
    Resources: RDS, ElastiCache, Database Proxies

  EFS Subnets:
    - CoreBank-EFS-1A: 10.0.31.0/24 (AZ-1a)
    - CoreBank-EFS-1B: 10.0.32.0/24 (AZ-1b)
    - CoreBank-EFS-1C: 10.0.33.0/24 (AZ-1c)
    Resources: EFS Mount Targets, NFS Endpoints
```

### Satellite VPCs

#### Satellite-1 VPC (10.1.0.0/16) - Cards & Payments

```yaml
VPC Configuration:
  CIDR: 10.1.0.0/16
  Region: ap-southeast-1
  Availability Zones: [1a, 1b]
  Purpose: Cards and Payment Processing

Subnet Design:
  Public Subnets:
    - Satellite1-Public-1A: 10.1.1.0/24 (AZ-1a)
    - Satellite1-Public-1B: 10.1.2.0/24 (AZ-1b)

  Private Application Subnets:
    - Satellite1-App-1A: 10.1.11.0/24 (AZ-1a)
    - Satellite1-App-1B: 10.1.12.0/24 (AZ-1b)

  EFS Subnets:
    - Satellite1-EFS-1A: 10.1.31.0/24 (AZ-1a)
    - Satellite1-EFS-1B: 10.1.32.0/24 (AZ-1b)
```

#### Satellite-2 VPC (10.2.0.0/16) - Loans & Deposits

```yaml
VPC Configuration:
  CIDR: 10.2.0.0/16
  Region: ap-southeast-1
  Availability Zones: [1a, 1b]
  Purpose: Loan and Deposit Services

Subnet Design:
  Public Subnets:
    - Satellite2-Public-1A: 10.2.1.0/24 (AZ-1a)
    - Satellite2-Public-1B: 10.2.2.0/24 (AZ-1b)

  Private Application Subnets:
    - Satellite2-App-1A: 10.2.11.0/24 (AZ-1a)
    - Satellite2-App-1B: 10.2.12.0/24 (AZ-1b)

  EFS Subnets:
    - Satellite2-EFS-1A: 10.2.31.0/24 (AZ-1a)
    - Satellite2-EFS-1B: 10.2.32.0/24 (AZ-1b)
```

## VPC Peering Configuration

### Peering Connections

```yaml
CoreBank-to-Satellite1:
  Connection ID: pcx-corebank-satellite1
  Requester: CoreBank VPC (10.0.0.0/16)
  Accepter: Satellite-1 VPC (10.1.0.0/16)
  Status: Active
  DNS Resolution: Enabled
  
CoreBank-to-Satellite2:
  Connection ID: pcx-corebank-satellite2
  Requester: CoreBank VPC (10.0.0.0/16)
  Accepter: Satellite-2 VPC (10.2.0.0/16)
  Status: Active
  DNS Resolution: Enabled
```

### Route Table Configuration

#### CoreBank Route Tables

```yaml
Public Route Table:
  Routes:
    - 0.0.0.0/0 → Internet Gateway
    - 10.0.0.0/16 → Local
    - 10.1.0.0/16 → pcx-corebank-satellite1
    - 10.2.0.0/16 → pcx-corebank-satellite2

Private App Route Table:
  Routes:
    - 0.0.0.0/0 → NAT Gateway
    - 10.0.0.0/16 → Local
    - 10.1.0.0/16 → pcx-corebank-satellite1
    - 10.2.0.0/16 → pcx-corebank-satellite2

Private DB Route Table:
  Routes:
    - 10.0.0.0/16 → Local
    - 10.1.0.0/16 → pcx-corebank-satellite1
    - 10.2.0.0/16 → pcx-corebank-satellite2

EFS Route Table:
  Routes:
    - 10.0.0.0/16 → Local
    - 10.1.0.0/16 → pcx-corebank-satellite1
    - 10.2.0.0/16 → pcx-corebank-satellite2
```

#### Satellite Route Tables

```yaml
Satellite-1 Route Tables:
  Public Route Table:
    - 0.0.0.0/0 → Internet Gateway
    - 10.1.0.0/16 → Local
    - 10.0.0.0/16 → pcx-corebank-satellite1

  Private Route Table:
    - 0.0.0.0/0 → NAT Gateway
    - 10.1.0.0/16 → Local
    - 10.0.0.0/16 → pcx-corebank-satellite1

Satellite-2 Route Tables:
  Public Route Table:
    - 0.0.0.0/0 → Internet Gateway
    - 10.2.0.0/16 → Local
    - 10.0.0.0/16 → pcx-corebank-satellite2

  Private Route Table:
    - 0.0.0.0/0 → NAT Gateway
    - 10.2.0.0/16 → Local
    - 10.0.0.0/16 → pcx-corebank-satellite2
```

## Security Groups

### EFS Security Groups

#### CoreBank EFS Security Group

```yaml
Name: sg-efs-corebank
Description: Security group for CoreBank shared EFS
VPC: CoreBank VPC

Inbound Rules:
  - Type: NFS (2049)
    Protocol: TCP
    Source: 10.0.0.0/16
    Description: NFS access from CoreBank VPC
  - Type: NFS (2049)
    Protocol: TCP
    Source: 10.1.0.0/16
    Description: NFS access from Satellite-1 VPC
  - Type: NFS (2049)
    Protocol: TCP
    Source: 10.2.0.0/16
    Description: NFS access from Satellite-2 VPC

Outbound Rules:
  - Type: All Traffic
    Protocol: All
    Destination: 0.0.0.0/0
    Description: All outbound traffic
```

#### Satellite EFS Security Groups

```yaml
Satellite-1 EFS Security Group:
  Name: sg-efs-satellite1
  Inbound Rules:
    - Type: NFS (2049)
      Protocol: TCP
      Source: 10.1.0.0/16
      Description: NFS access from Satellite-1 VPC

Satellite-2 EFS Security Group:
  Name: sg-efs-satellite2
  Inbound Rules:
    - Type: NFS (2049)
      Protocol: TCP
      Source: 10.2.0.0/16
      Description: NFS access from Satellite-2 VPC
```

### EKS Security Groups

#### CoreBank EKS Security Groups

```yaml
EKS Cluster Security Group:
  Name: sg-eks-cluster-corebank
  Description: EKS cluster control plane security group
  
  Inbound Rules:
    - Type: HTTPS (443)
      Protocol: TCP
      Source: sg-eks-nodes-corebank
      Description: Node to cluster API communication

EKS Node Security Group:
  Name: sg-eks-nodes-corebank
  Description: EKS worker nodes security group
  
  Inbound Rules:
    - Type: All Traffic
      Protocol: All
      Source: sg-eks-nodes-corebank
      Description: Inter-node communication
    - Type: HTTPS (443)
      Protocol: TCP
      Source: sg-eks-cluster-corebank
      Description: Cluster to node communication
    - Type: Custom TCP (10250)
      Protocol: TCP
      Source: sg-eks-cluster-corebank
      Description: Kubelet API
    - Type: Custom TCP (53)
      Protocol: TCP/UDP
      Source: 10.0.0.0/16
      Description: DNS resolution
```

### Database Security Groups

```yaml
RDS Security Group:
  Name: sg-rds-corebank
  Description: RDS PostgreSQL security group
  
  Inbound Rules:
    - Type: PostgreSQL (5432)
      Protocol: TCP
      Source: sg-eks-nodes-corebank
      Description: Database access from EKS nodes

ElastiCache Security Group:
  Name: sg-elasticache-corebank
  Description: ElastiCache Redis security group
  
  Inbound Rules:
    - Type: Custom TCP (6379)
      Protocol: TCP
      Source: sg-eks-nodes-corebank
      Description: Redis access from EKS nodes
```

## Network ACLs

### CoreBank Network ACLs

```yaml
Public Subnet NACL:
  Inbound Rules:
    100: Allow HTTP (80) from 0.0.0.0/0
    110: Allow HTTPS (443) from 0.0.0.0/0
    120: Allow SSH (22) from Corporate IP Range
    130: Allow Ephemeral (1024-65535) from 0.0.0.0/0
    32767: Deny All from 0.0.0.0/0

  Outbound Rules:
    100: Allow All Traffic to 0.0.0.0/0
    32767: Deny All to 0.0.0.0/0

Private Subnet NACL:
  Inbound Rules:
    100: Allow All Traffic from 10.0.0.0/16
    110: Allow All Traffic from 10.1.0.0/16
    120: Allow All Traffic from 10.2.0.0/16
    130: Allow Ephemeral (1024-65535) from 0.0.0.0/0
    32767: Deny All from 0.0.0.0/0

  Outbound Rules:
    100: Allow All Traffic to 0.0.0.0/0
    32767: Deny All to 0.0.0.0/0

Database Subnet NACL:
  Inbound Rules:
    100: Allow PostgreSQL (5432) from 10.0.11.0/24
    110: Allow PostgreSQL (5432) from 10.0.12.0/24
    120: Allow PostgreSQL (5432) from 10.0.13.0/24
    130: Allow Redis (6379) from 10.0.11.0/24
    140: Allow Redis (6379) from 10.0.12.0/24
    150: Allow Redis (6379) from 10.0.13.0/24
    32767: Deny All from 0.0.0.0/0

  Outbound Rules:
    100: Allow All Traffic to 10.0.0.0/16
    32767: Deny All to 0.0.0.0/0
```

## Network Performance Optimization

### Placement Groups

```yaml
EKS Node Placement Groups:
  CoreBank Cluster:
    Type: cluster
    Strategy: cluster
    Purpose: Low latency between nodes

  Satellite Clusters:
    Type: partition
    Strategy: partition
    Purpose: Fault isolation
```

### Enhanced Networking

```yaml
Instance Types with Enhanced Networking:
  CoreBank Nodes: c5.xlarge (Up to 10 Gbps)
  Satellite Nodes: c5.large (Up to 10 Gbps)
  
Features Enabled:
  - SR-IOV
  - Enhanced Networking
  - Placement Groups
  - EBS Optimization
```

### Network Monitoring

```yaml
VPC Flow Logs:
  Destination: CloudWatch Logs
  Traffic Type: ALL
  Log Format: Custom
  Fields:
    - srcaddr, dstaddr, srcport, dstport
    - protocol, packets, bytes
    - windowstart, windowend
    - action, flowlogstatus

CloudWatch Metrics:
  - NetworkIn/NetworkOut
  - NetworkPacketsIn/NetworkPacketsOut
  - NetworkLatency
  - PacketDropCount
```

## DNS Configuration

### Route53 Private Hosted Zones

```yaml
CoreBank Private Zone:
  Domain: corebank.internal
  VPC Associations: [CoreBank VPC]
  Records:
    - rds.corebank.internal → RDS Endpoint
    - redis.corebank.internal → ElastiCache Endpoint
    - efs.corebank.internal → EFS DNS Name

Cross-Account DNS Resolution:
  Satellite-1 Zone:
    Domain: satellite1.internal
    VPC Associations: [Satellite-1 VPC, CoreBank VPC]
  
  Satellite-2 Zone:
    Domain: satellite2.internal
    VPC Associations: [Satellite-2 VPC, CoreBank VPC]
```

## Network Security Best Practices

### 1. Defense in Depth
- Multiple layers of security controls
- Network segmentation with subnets
- Security groups and NACLs
- VPC Flow Logs for monitoring

### 2. Least Privilege Access
- Minimal required ports and protocols
- Source-specific security group rules
- Regular access review and cleanup
- Automated compliance checking

### 3. Encryption in Transit
- TLS 1.2+ for all communications
- VPN connections for management access
- Encrypted EFS mounts
- Database connection encryption

### 4. Monitoring and Alerting
- Real-time network monitoring
- Anomaly detection
- Security event alerting
- Regular security assessments

## Troubleshooting Network Issues

### Common Network Problems

#### Connectivity Issues
```bash
# Test VPC peering connectivity
ping 10.1.1.1  # From CoreBank to Satellite-1
ping 10.0.1.1  # From Satellite-1 to CoreBank

# Check route tables
aws ec2 describe-route-tables --filters "Name=vpc-id,Values=vpc-xxxxxxxxx"

# Verify security groups
aws ec2 describe-security-groups --group-ids sg-xxxxxxxxx
```

#### EFS Mount Issues
```bash
# Test NFS connectivity
telnet fs-xxxxxxxxx.efs.ap-southeast-1.amazonaws.com 2049

# Check EFS mount targets
aws efs describe-mount-targets --file-system-id fs-xxxxxxxxx

# Verify DNS resolution
nslookup fs-xxxxxxxxx.efs.ap-southeast-1.amazonaws.com
```

#### Performance Issues
```bash
# Monitor network metrics
aws cloudwatch get-metric-statistics \
  --namespace AWS/EC2 \
  --metric-name NetworkIn \
  --dimensions Name=InstanceId,Value=i-xxxxxxxxx \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Average

# Check VPC Flow Logs
aws logs filter-log-events \
  --log-group-name VPCFlowLogs \
  --start-time $(date -d '1 hour ago' +%s)000 \
  --filter-pattern "{ $.action = \"REJECT\" }"
```

This network design provides a secure, scalable, and high-performance foundation for the cross-account EFS solution while meeting banking industry compliance requirements.
