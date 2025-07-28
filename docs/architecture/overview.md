# Architecture Overview

## Introduction

This document provides a comprehensive overview of the cross-account Amazon EFS mounting solution for Amazon EKS clusters, specifically designed for banking and financial services environments.

## Architecture Principles

### 1. Security First
- **Principle of Least Privilege**: All IAM roles and policies follow minimal access requirements
- **Defense in Depth**: Multiple layers of security controls
- **Encryption Everywhere**: Data encrypted at rest and in transit
- **Audit Trail**: Complete logging and monitoring of all operations

### 2. High Availability
- **Multi-AZ Deployment**: Resources distributed across availability zones
- **Redundancy**: No single points of failure
- **Auto-Recovery**: Automated failover and recovery mechanisms
- **Load Distribution**: Traffic distributed across multiple instances

### 3. Performance Optimization
- **Sub-Minute Recovery**: RTO < 60 seconds
- **Low Latency**: API response times < 200ms
- **High Throughput**: Optimized EFS performance modes
- **Efficient Scaling**: Auto-scaling based on demand

### 4. Operational Excellence
- **Infrastructure as Code**: All resources defined in Terraform
- **Automated Deployment**: Scripted deployment and configuration
- **Comprehensive Monitoring**: Real-time metrics and alerting
- **Documentation**: Complete operational procedures

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Banking Cross-Account Architecture            │
│                         (ap-southeast-1)                       │
└─────────────────────────────────────────────────────────────────┘

                              ┌─────────────────┐
                              │   Route53 DNS   │
                              │  Health Checks  │
                              └─────────────────┘
                                       │
                              ┌─────────────────┐
                              │  CloudFront CDN │
                              │  WAF Protection │
                              └─────────────────┘
                                       │
        ┌──────────────────────────────┼──────────────────────────────┐
        │                              │                              │
┌───────▼──────┐              ┌────────▼────────┐              ┌─────▼──────┐
│ CoreBank Acc │              │ Satellite Acc 1 │              │Satellite   │
│(111111111111)│              │ (222222222222)  │              │Acc 2       │
│              │              │                 │              │(3333333333)│
│┌────────────┐│              │┌───────────────┐│              │┌──────────┐│
││EKS CoreBank││              ││EKS Satellite-1││              ││EKS       ││
││  Cluster   ││              ││   Cluster     ││              ││Satellite-││
││            ││              ││               ││              ││2 Cluster ││
│└────────────┘│              │└───────────────┘│              │└──────────┘│
│              │              │                 │              │            │
│┌────────────┐│    ┌─────────┤┌───────────────┐│              │┌──────────┐│
││EFS CoreBank│◄────┤Cross-   ││EFS Mount      ││              ││EFS Mount ││
││ (Shared)   ││    │Account  ││(Cross-Account)││              ││(Cross-   ││
││            ││    │Access   │└───────────────┘│              ││Account)  ││
│└────────────┘│    └─────────┤┌───────────────┐│              │└──────────┘│
│              │              ││EFS Local-1    ││              │┌──────────┐│
│┌────────────┐│              ││               ││              ││EFS       ││
││RDS Primary ││              │└───────────────┘│              ││Local-2   ││
││  Multi-AZ  ││              └─────────────────┘              │└──────────┘│
│└────────────┘│                                               └────────────┘
│              │
│┌────────────┐│
││ElastiCache ││
││   Redis    ││
│└────────────┘│
└──────────────┘
```

## Component Architecture

### 1. CoreBank Account Components

#### EKS Cluster
- **Purpose**: Hosts core banking applications
- **Configuration**: 
  - Node Type: c5.xlarge (4 vCPU, 8GB RAM)
  - Min/Max Nodes: 3/10
  - Auto-scaling enabled
- **Features**:
  - Multi-AZ deployment
  - Managed node groups
  - EFS CSI driver
  - Load balancer controller

#### EFS Shared Storage
- **Purpose**: Central data repository for all banking data
- **Configuration**:
  - Performance Mode: General Purpose
  - Throughput Mode: Provisioned (1000 MiB/s)
  - Encryption: Enabled (at rest and in transit)
- **Access Points**:
  - Satellite-1 Access Point: `/satellite1`
  - Satellite-2 Access Point: `/satellite2`

#### RDS Database
- **Purpose**: Transactional data storage
- **Configuration**:
  - Engine: PostgreSQL 15.4
  - Instance: db.r5.xlarge
  - Multi-AZ: Enabled
  - Backup: 7 days retention

#### ElastiCache Redis
- **Purpose**: Caching and session storage
- **Configuration**:
  - Node Type: cache.r6g.large
  - Cluster Mode: Enabled
  - Shards: 3, Replicas: 2

### 2. Satellite Account Components

#### EKS Clusters
- **Purpose**: Host satellite banking applications
- **Configuration**:
  - Node Type: c5.large (2 vCPU, 4GB RAM)
  - Min/Max Nodes: 2/6
  - Auto-scaling enabled

#### Dual EFS Storage
Each satellite account has two EFS mount points:

1. **Local EFS**
   - Purpose: Local data storage and caching
   - Throughput: 500 MiB/s provisioned
   - Access: Account-local only

2. **Cross-Account EFS Mount**
   - Purpose: Access to CoreBank shared EFS
   - Access: Via EFS Access Points
   - Security: Cross-account IAM roles

## Network Architecture

### VPC Design

```
CoreBank VPC (10.0.0.0/16)
├── Public Subnets
│   ├── 10.0.1.0/24 (AZ-1a) - NAT Gateway, ALB
│   ├── 10.0.2.0/24 (AZ-1b) - NAT Gateway, ALB
│   └── 10.0.3.0/24 (AZ-1c) - NAT Gateway, ALB
├── Private App Subnets
│   ├── 10.0.11.0/24 (AZ-1a) - EKS Nodes
│   ├── 10.0.12.0/24 (AZ-1b) - EKS Nodes
│   └── 10.0.13.0/24 (AZ-1c) - EKS Nodes
├── Private DB Subnets
│   ├── 10.0.21.0/24 (AZ-1a) - RDS, ElastiCache
│   ├── 10.0.22.0/24 (AZ-1b) - RDS, ElastiCache
│   └── 10.0.23.0/24 (AZ-1c) - RDS, ElastiCache
└── EFS Subnets
    ├── 10.0.31.0/24 (AZ-1a) - EFS Mount Targets
    ├── 10.0.32.0/24 (AZ-1b) - EFS Mount Targets
    └── 10.0.33.0/24 (AZ-1c) - EFS Mount Targets

Satellite-1 VPC (10.1.0.0/16)
├── Public Subnets: 10.1.1.0/24, 10.1.2.0/24
├── Private Subnets: 10.1.11.0/24, 10.1.12.0/24
└── EFS Subnets: 10.1.31.0/24, 10.1.32.0/24

Satellite-2 VPC (10.2.0.0/16)
├── Public Subnets: 10.2.1.0/24, 10.2.2.0/24
├── Private Subnets: 10.2.11.0/24, 10.2.12.0/24
└── EFS Subnets: 10.2.31.0/24, 10.2.32.0/24
```

### VPC Peering

```
Peering Connections:
- CoreBank VPC ↔ Satellite-1 VPC
- CoreBank VPC ↔ Satellite-2 VPC

Route Tables:
- CoreBank → Satellite-1: 10.1.0.0/16 via pcx-12345
- CoreBank → Satellite-2: 10.2.0.0/16 via pcx-67890
- Satellite-1 → CoreBank: 10.0.0.0/16 via pcx-12345
- Satellite-2 → CoreBank: 10.0.0.0/16 via pcx-67890
```

## Data Flow Architecture

### Dual-Write Pattern

```
┌─────────────────┐
│ Satellite App   │
└─────────┬───────┘
          │
    ┌─────▼─────┐
    │Write Data │
    └─────┬─────┘
          │
    ┌─────▼─────┐
    │ Parallel  │
    │ Execution │
    └─┬───────┬─┘
      │       │
┌─────▼─┐   ┌─▼──────────┐
│Local  │   │Cross-      │
│EFS    │   │Account EFS │
│Write  │   │Write       │
└───────┘   └────────────┘
```

### Write Flow Sequence

1. **Application Receives Request**
   - Validate input data
   - Prepare for dual-write operation

2. **Parallel Write Execution**
   - Start local EFS write (fast path)
   - Start cross-account EFS write (sync path)
   - Execute both operations concurrently

3. **Write Completion**
   - Wait for both writes to complete
   - Handle partial failures gracefully
   - Return success if at least local write succeeds

4. **Error Handling**
   - Retry failed operations
   - Log failures for monitoring
   - Trigger alerts if needed

### Read Flow Sequence

1. **Read Request**
   - Determine data location (local vs. cross-account)
   - Route request to appropriate EFS

2. **Data Retrieval**
   - Read from local EFS (preferred)
   - Fallback to cross-account EFS if needed

3. **Response**
   - Return data to application
   - Cache frequently accessed data

## Security Architecture

### Cross-Account Access Model

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   CoreBank      │    │   Satellite-1   │    │   Satellite-2   │
│                 │    │                 │    │                 │
│ ┌─────────────┐ │    │ ┌─────────────┐ │    │ ┌─────────────┐ │
│ │EFS Resource │ │    │ │Cross-Account│ │    │ │Cross-Account│ │
│ │Policy       │ │    │ │IAM Role     │ │    │ │IAM Role     │ │
│ │             │ │    │ │             │ │    │ │             │ │
│ │Allow:       │ │    │ │AssumeRole   │ │    │ │AssumeRole   │ │
│ │- Satellite-1│◄┼────┼─┤Permissions  │ │    │ │Permissions  │ │
│ │- Satellite-2│◄┼────┼─┤             │ │    │ │             │ │
│ └─────────────┘ │    │ └─────────────┘ │    │ └─────────────┘ │
│                 │    │                 │    │                 │
│ ┌─────────────┐ │    │                 │    │                 │
│ │EFS Access   │ │    │                 │    │                 │
│ │Points       │ │    │                 │    │                 │
│ │- /satellite1│ │    │                 │    │                 │
│ │- /satellite2│ │    │                 │    │                 │
│ └─────────────┘ │    │                 │    │                 │
└─────────────────┘    └─────────────────┘    └─────────────────┘
```

### Security Controls

1. **Network Security**
   - VPC isolation
   - Security groups with minimal access
   - NACLs for additional protection
   - VPC Flow Logs enabled

2. **Identity and Access Management**
   - Cross-account IAM roles
   - Least privilege access
   - MFA for administrative access
   - Regular access reviews

3. **Data Protection**
   - Encryption at rest (KMS)
   - Encryption in transit (TLS)
   - EFS Access Points for granular control
   - Backup encryption

4. **Monitoring and Auditing**
   - CloudTrail for API logging
   - VPC Flow Logs for network monitoring
   - EFS access logging
   - Real-time security monitoring

## Performance Architecture

### Performance Targets

| Metric | Target | Measurement |
|--------|--------|-------------|
| RTO (Recovery Time Objective) | < 60 seconds | Time to restore service |
| RPO (Recovery Point Objective) | < 30 seconds | Maximum data loss |
| API Response Time | < 200ms (95th percentile) | Application response |
| EFS Dual-Write Time | < 60 seconds | Cross-account sync |
| System Availability | 99.99% | Monthly uptime |

### Performance Optimizations

1. **EFS Performance**
   - Provisioned throughput mode
   - Optimized mount options
   - Connection pooling
   - Local caching

2. **Application Performance**
   - Async I/O operations
   - Connection pooling
   - Batch processing
   - Efficient serialization

3. **Network Performance**
   - Placement groups
   - Enhanced networking
   - Optimized instance types
   - Load balancer optimization

4. **Database Performance**
   - Connection pooling
   - Read replicas
   - Query optimization
   - Caching strategies

## Monitoring Architecture

### Metrics Collection

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Application   │    │   Infrastructure│    │    Business     │
│    Metrics      │    │     Metrics     │    │    Metrics      │
│                 │    │                 │    │                 │
│• Response Time  │    │• CPU/Memory     │    │• Transaction    │
│• Error Rate     │    │• Network I/O    │    │  Volume         │
│• Throughput     │    │• Disk I/O       │    │• Success Rate   │
│• Dual-Write     │    │• EFS Performance│    │• Revenue Impact │
│  Latency        │    │                 │    │                 │
└─────────┬───────┘    └─────────┬───────┘    └─────────┬───────┘
          │                      │                      │
          └──────────────────────┼──────────────────────┘
                                 │
                    ┌─────────────▼─────────────┐
                    │      CloudWatch          │
                    │   Metrics & Alarms       │
                    └─────────────┬─────────────┘
                                 │
                    ┌─────────────▼─────────────┐
                    │     Notification         │
                    │   SNS → Slack/Email      │
                    └──────────────────────────┘
```

### Alerting Strategy

1. **Critical Alerts** (Immediate Response)
   - System down or unavailable
   - Data corruption detected
   - Security breach indicators
   - Cross-account access failures

2. **Warning Alerts** (Response within 15 minutes)
   - Performance degradation
   - High error rates
   - Resource utilization > 80%
   - Backup failures

3. **Informational Alerts** (Response within 1 hour)
   - Capacity planning thresholds
   - Cost optimization opportunities
   - Maintenance reminders

## Disaster Recovery Architecture

### Recovery Strategies

1. **High Availability (HA)**
   - Multi-AZ deployment
   - Auto-scaling groups
   - Load balancer health checks
   - Automated failover

2. **Backup and Restore**
   - EFS automatic backups
   - RDS automated backups
   - Cross-region backup replication
   - Point-in-time recovery

3. **Disaster Recovery (DR)**
   - Cross-region replication
   - Infrastructure as Code
   - Automated DR procedures
   - Regular DR testing

### Recovery Procedures

1. **Automated Recovery**
   - Health check failures trigger auto-scaling
   - Load balancer removes unhealthy targets
   - EKS replaces failed nodes automatically
   - Database failover to standby

2. **Manual Recovery**
   - Cross-region failover procedures
   - Data restoration from backups
   - Infrastructure recreation
   - Application redeployment

## Compliance and Governance

### Banking Compliance

1. **Data Residency**
   - All data remains in ap-southeast-1
   - No cross-border data transfer
   - Compliance with local regulations

2. **Audit Requirements**
   - Complete audit trail
   - 7-year data retention
   - Regular compliance assessments
   - Third-party audits

3. **Security Standards**
   - PCI DSS compliance
   - ISO 27001 alignment
   - SOC 2 Type II
   - Regular penetration testing

### Governance Framework

1. **Change Management**
   - Infrastructure as Code
   - Peer review process
   - Automated testing
   - Rollback procedures

2. **Access Control**
   - Role-based access control
   - Regular access reviews
   - Privileged access management
   - Multi-factor authentication

3. **Risk Management**
   - Regular risk assessments
   - Threat modeling
   - Incident response procedures
   - Business continuity planning

## Conclusion

This architecture provides a robust, secure, and high-performance solution for cross-account EFS mounting in banking environments. The design emphasizes security, compliance, and operational excellence while meeting stringent performance requirements.

The dual-write pattern ensures data consistency and availability, while the cross-account access model provides secure isolation between different banking services. Comprehensive monitoring and alerting ensure rapid detection and resolution of issues.

For detailed implementation guidance, refer to the deployment documentation and infrastructure code provided in this repository.
