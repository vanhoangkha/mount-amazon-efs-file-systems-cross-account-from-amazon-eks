# Architecture Overview

## Introduction

This document provides a comprehensive overview of the cross-account Amazon EFS mounting solution for Amazon EKS clusters, specifically designed for testing and validating EFS cross-account functionality.

## Architecture Principles

### 1. Simplicity First
- **Minimal Dependencies**: Focus on EFS testing without database complexity
- **Clear Purpose**: Dedicated to validating cross-account EFS functionality
- **Easy Deployment**: Streamlined setup and testing process
- **Comprehensive Testing**: Thorough validation of all EFS operations

### 2. Security by Design
- **Principle of Least Privilege**: All IAM roles follow minimal access requirements
- **Cross-Account Isolation**: Secure boundaries between AWS accounts
- **Encryption Everywhere**: Data encrypted at rest and in transit
- **Audit Trail**: Complete logging of all EFS operations

### 3. Performance Validation
- **Dual-Write Testing**: Validate simultaneous writes to multiple EFS systems
- **Latency Measurement**: Track performance across accounts
- **Throughput Testing**: Validate EFS performance limits
- **Consistency Verification**: Ensure data integrity across accounts

## High-Level Architecture

![Cross-Account EFS Architecture](../../architecture/diagrams/efs-cross-account-architecture.png)

*Figure 1: Simplified cross-account EFS architecture with test applications*

The architecture consists of three main components:

1. **CoreBank Account**: Central hub containing shared EFS and test application
2. **Satellite Account 1**: Test application with dual EFS mounts (local + cross-account)
3. **Satellite Account 2**: Test application with dual EFS mounts (local + cross-account)

Each satellite account implements a dual-write pattern where applications write to both local EFS (for performance) and CoreBank EFS (for cross-account validation).

## Network Architecture

![Network Architecture](../../architecture/diagrams/efs-network-architecture.png)

*Figure 2: Network topology showing VPC peering and EFS test application deployment*

### VPC Design

The network architecture implements a hub-and-spoke model with VPC peering:

- **CoreBank VPC (10.0.0.0/16)**: Central hub with EFS test application
- **Satellite-1 VPC (10.1.0.0/16)**: Test application with dual EFS access
- **Satellite-2 VPC (10.2.0.0/16)**: Test application with dual EFS access

### Connectivity Model

```
VPC Peering Connections:
- CoreBank VPC ↔ Satellite-1 VPC
- CoreBank VPC ↔ Satellite-2 VPC

Route Tables:
- CoreBank → Satellite-1: 10.1.0.0/16 via pcx-12345
- CoreBank → Satellite-2: 10.2.0.0/16 via pcx-67890
- Satellite-1 → CoreBank: 10.0.0.0/16 via pcx-12345
- Satellite-2 → CoreBank: 10.0.0.0/16 via pcx-67890
```

## Security Architecture

![Security Architecture](../../architecture/diagrams/efs-security-architecture.png)

*Figure 3: Security architecture with cross-account IAM roles and access controls*

### Cross-Account Access Model

The security architecture implements a zero-trust model with multiple layers of access control:

1. **Network Security**: VPC isolation with security groups
2. **Identity Management**: Cross-account IAM roles with IRSA
3. **Data Protection**: EFS access points for granular file system access
4. **Encryption**: End-to-end encryption using AWS KMS
5. **Monitoring**: Comprehensive audit logging

### Security Controls

The security model uses EFS Access Points to provide granular access control:

- **Satellite-1 Access Point**: `/satellite1` directory with UID/GID 1001
- **Satellite-2 Access Point**: `/satellite2` directory with UID/GID 1002
- **Cross-Account Roles**: IRSA-enabled service accounts for secure access
- **KMS Encryption**: All EFS systems encrypted with customer-managed keys

## Component Architecture

### 1. EFS Test Application

#### Purpose
- Validate cross-account EFS mounting functionality
- Test dual-write patterns between local and remote EFS
- Provide comprehensive testing APIs
- Monitor performance and reliability

#### Features
- **Health Checks**: Monitor EFS mount health
- **Dual-Write Operations**: Write to both local and cross-account EFS
- **Read Operations**: Read from specific EFS mounts
- **File Listing**: Browse EFS directory contents
- **Performance Metrics**: Track latency and throughput
- **Automated Testing**: Built-in test suites

#### API Endpoints
```
GET  /health          - Health check for EFS mounts
POST /write           - Write file with dual-write pattern
GET  /read            - Read file from specific mount
GET  /list            - List files in EFS directory
GET  /stats           - Get application statistics
POST /test            - Run automated test suite
```

### 2. EFS Storage Systems

#### CoreBank EFS (Shared)
- **Purpose**: Central data repository accessible from all accounts
- **Configuration**: Provisioned throughput (1000 MiB/s)
- **Access Control**: EFS Access Points for each satellite account
- **Encryption**: KMS encryption at rest and in transit

#### Satellite Local EFS
- **Purpose**: Local storage for each satellite account
- **Configuration**: Provisioned throughput (500 MiB/s)
- **Access Control**: Account-local access only
- **Encryption**: KMS encryption at rest and in transit

### 3. EKS Clusters

#### CoreBank Cluster
- **Node Type**: c5.large (2 vCPU, 4GB RAM)
- **Scaling**: 2-6 nodes with auto-scaling
- **Add-ons**: EFS CSI driver, AWS Load Balancer Controller
- **Purpose**: Host EFS test application

#### Satellite Clusters
- **Node Type**: c5.large (2 vCPU, 4GB RAM)
- **Scaling**: 1-4 nodes with auto-scaling
- **Add-ons**: EFS CSI driver, AWS Load Balancer Controller
- **Purpose**: Host EFS test applications with dual mounts

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
   - Start cross-account EFS write (validation path)
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
   - Read from specified EFS mount
   - Handle file not found scenarios

3. **Response**
   - Return data to application
   - Include metadata about source mount

## Testing Architecture

### Test Categories

#### 1. Health Testing
- **EFS Mount Health**: Verify both mounts are accessible
- **Write/Read Operations**: Basic functionality validation
- **Performance Metrics**: Latency and throughput measurement

#### 2. Functional Testing
- **Dual-Write Validation**: Ensure data written to both EFS systems
- **Cross-Account Access**: Verify cross-account EFS accessibility
- **Data Consistency**: Validate data integrity across mounts

#### 3. Performance Testing
- **Throughput Testing**: Measure files per second
- **Latency Testing**: Track write/read response times
- **Concurrent Operations**: Test multiple simultaneous operations

#### 4. Integration Testing
- **Cross-Account Consistency**: Verify data sync between accounts
- **Failover Testing**: Test behavior when one EFS is unavailable
- **Recovery Testing**: Validate system recovery capabilities

### Test Automation

The solution includes comprehensive test automation:

- **Automated Test Suite**: Built into each application
- **Health Monitoring**: Continuous health checks
- **Performance Tracking**: Real-time metrics collection
- **Failure Detection**: Automatic error detection and reporting

## Deployment Architecture

### Infrastructure as Code

The solution uses automated deployment scripts:

1. **EKS Deployment**: Automated cluster creation with required add-ons
2. **EFS Setup**: Automated EFS creation with cross-account policies
3. **Application Build**: Docker image build and ECR push
4. **Application Deployment**: Kubernetes manifest deployment
5. **Testing**: Automated functionality validation

### Deployment Sequence

```
1. Deploy EKS Clusters
   ├── Create clusters in all accounts
   ├── Install EFS CSI driver
   └── Configure IRSA for cross-account access

2. Deploy EFS Infrastructure
   ├── Create EFS systems
   ├── Setup cross-account policies
   ├── Create access points
   └── Configure security groups

3. Build and Deploy Applications
   ├── Build Docker images
   ├── Push to ECR repositories
   ├── Deploy to EKS clusters
   └── Configure dual EFS mounts

4. Validate Deployment
   ├── Run health checks
   ├── Execute test suites
   ├── Verify cross-account access
   └── Generate test reports
```

## Monitoring and Observability

### Metrics Collection

- **Application Metrics**: Response times, error rates, throughput
- **EFS Metrics**: Mount health, latency, throughput utilization
- **Infrastructure Metrics**: CPU, memory, network usage
- **Security Metrics**: Access attempts, authentication failures

### Logging

- **Application Logs**: Structured JSON logging
- **EFS Access Logs**: File system access tracking
- **Kubernetes Logs**: Pod and cluster events
- **Security Logs**: IAM role assumptions, policy violations

### Alerting

- **Health Alerts**: EFS mount failures, application errors
- **Performance Alerts**: High latency, low throughput
- **Security Alerts**: Unauthorized access attempts
- **Infrastructure Alerts**: Resource utilization thresholds

## Conclusion

This architecture provides a comprehensive solution for testing and validating cross-account EFS functionality. The simplified design focuses on the core EFS capabilities while maintaining security best practices and providing thorough testing capabilities.

The solution is designed to be:
- **Easy to deploy**: Automated scripts for complete setup
- **Comprehensive**: Full testing of EFS cross-account features
- **Secure**: Proper IAM roles and encryption
- **Observable**: Complete monitoring and logging
- **Scalable**: Auto-scaling based on demand

For detailed implementation guidance, refer to the deployment documentation and infrastructure code provided in this repository.
