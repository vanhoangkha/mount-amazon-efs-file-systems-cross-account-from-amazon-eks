# Security Model

## Overview

This document outlines the comprehensive security model for the cross-account EFS solution, designed to meet banking industry security standards and regulatory compliance requirements.

## Security Architecture Diagram

![Security Architecture](../../architecture/diagrams/banking-security-cross-account.png)

*Figure 1: Cross-account security architecture showing IAM roles, access controls, and security boundaries*

## Security Principles

### 1. Zero Trust Architecture
- **Never Trust, Always Verify**: Every request is authenticated and authorized
- **Least Privilege Access**: Minimal permissions required for functionality
- **Assume Breach**: Design with the assumption that perimeter security may be compromised
- **Continuous Monitoring**: Real-time security monitoring and alerting

### 2. Defense in Depth
- **Multiple Security Layers**: Network, application, and data-level security
- **Redundant Controls**: Multiple overlapping security mechanisms
- **Fail-Safe Defaults**: Secure by default configurations
- **Security Automation**: Automated security controls and responses

### 3. Compliance by Design
- **Regulatory Alignment**: Built-in compliance with banking regulations
- **Audit Trail**: Comprehensive logging for compliance reporting
- **Data Protection**: Encryption and access controls for sensitive data
- **Regular Assessments**: Continuous compliance monitoring

## Identity and Access Management

### Cross-Account IAM Architecture

The security model implements a sophisticated cross-account IAM structure:

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   CoreBank      │    │   Satellite-1   │    │   Satellite-2   │
│   Account       │    │   Account       │    │   Account       │
│                 │    │                 │    │                 │
│ ┌─────────────┐ │    │ ┌─────────────┐ │    │ ┌─────────────┐ │
│ │EFS Resource │ │    │ │Cross-Account│ │    │ │Cross-Account│ │
│ │Policy       │ │    │ │IAM Role     │ │    │ │IAM Role     │ │
│ │             │ │◄───┼─┤             │ │    │ │             │ │
│ │Trust Policy │ │    │ │AssumeRole   │ │    │ │AssumeRole   │ │
│ │for Satellite│ │    │ │Permissions  │ │    │ │Permissions  │ │
│ │Accounts     │ │    │ │             │ │    │ │             │ │
│ └─────────────┘ │    │ └─────────────┘ │    │ └─────────────┘ │
│                 │    │                 │    │                 │
│ ┌─────────────┐ │    │ ┌─────────────┐ │    │ ┌─────────────┐ │
│ │EFS Access   │ │    │ │EKS Service  │ │    │ │EKS Service  │ │
│ │Points       │ │    │ │Account      │ │    │ │Account      │ │
│ │- /satellite1│ │    │ │             │ │    │ │             │ │
│ │- /satellite2│ │    │ │IRSA Role    │ │    │ │IRSA Role    │ │
│ └─────────────┘ │    │ └─────────────┘ │    │ └─────────────┘ │
└─────────────────┘    └─────────────────┘    └─────────────────┘
```

### IAM Roles and Policies

#### CoreBank Account - EFS Resource Policy

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowCrossAccountEFSAccess",
      "Effect": "Allow",
      "Principal": {
        "AWS": [
          "arn:aws:iam::222222222222:role/Satellite1-EFS-CrossAccount-Role",
          "arn:aws:iam::333333333333:role/Satellite2-EFS-CrossAccount-Role"
        ]
      },
      "Action": [
        "elasticfilesystem:ClientMount",
        "elasticfilesystem:ClientWrite",
        "elasticfilesystem:ClientRootAccess"
      ],
      "Resource": "arn:aws:elasticfilesystem:ap-southeast-1:111111111111:file-system/fs-corebank123",
      "Condition": {
        "StringEquals": {
          "elasticfilesystem:AccessPointArn": [
            "arn:aws:elasticfilesystem:ap-southeast-1:111111111111:access-point/fsap-satellite1",
            "arn:aws:elasticfilesystem:ap-southeast-1:111111111111:access-point/fsap-satellite2"
          ]
        },
        "IpAddress": {
          "aws:SourceIp": [
            "10.1.0.0/16",
            "10.2.0.0/16"
          ]
        },
        "DateGreaterThan": {
          "aws:CurrentTime": "2024-01-01T00:00:00Z"
        },
        "DateLessThan": {
          "aws:CurrentTime": "2025-12-31T23:59:59Z"
        }
      }
    }
  ]
}
```

#### Satellite Account - Cross-Account IAM Role

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::222222222222:oidc-provider/oidc.eks.ap-southeast-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B716D3041E"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.ap-southeast-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B716D3041E:sub": "system:serviceaccount:banking:satellite-app",
          "oidc.eks.ap-southeast-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B716D3041E:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
```

#### EKS Service Account Role (IRSA)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "sts:AssumeRole"
      ],
      "Resource": "arn:aws:iam::111111111111:role/CoreBank-EFS-CrossAccount-Access-Role",
      "Condition": {
        "StringEquals": {
          "sts:ExternalId": "satellite1-efs-access-2024"
        }
      }
    },
    {
      "Effect": "Allow",
      "Action": [
        "elasticfilesystem:DescribeFileSystems",
        "elasticfilesystem:DescribeAccessPoints",
        "elasticfilesystem:DescribeMountTargets"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "cloudwatch:PutMetricData"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "cloudwatch:namespace": [
            "Banking/Performance",
            "Banking/EFS",
            "Banking/Security"
          ]
        }
      }
    }
  ]
}
```

## Data Protection

### Encryption Strategy

#### 1. Encryption at Rest

```yaml
EFS Encryption:
  Encryption: Enabled
  KMS Key: Customer Managed Key (CMK)
  Key Policy: Cross-account access for satellite accounts
  Key Rotation: Enabled (Annual)

RDS Encryption:
  Encryption: Enabled
  KMS Key: Customer Managed Key (CMK)
  Backup Encryption: Enabled
  Snapshot Encryption: Enabled

EBS Encryption:
  Default Encryption: Enabled
  KMS Key: Customer Managed Key (CMK)
  All Volumes: Encrypted by default

S3 Encryption:
  Default Encryption: SSE-KMS
  KMS Key: Customer Managed Key (CMK)
  Bucket Key: Enabled for cost optimization
```

#### 2. Encryption in Transit

```yaml
EFS Mount Encryption:
  TLS: Enabled (stunnel/efs-utils)
  Port: 20049 (encrypted NFS)
  Certificate Validation: Enabled

Database Connections:
  SSL/TLS: Required (TLS 1.2+)
  Certificate Validation: Enabled
  Connection Encryption: Forced

Application Communications:
  HTTPS: Required (TLS 1.2+)
  Internal APIs: mTLS
  Service Mesh: Istio with automatic TLS
```

#### 3. Key Management

```yaml
KMS Key Configuration:
  Key Type: Customer Managed Key (CMK)
  Key Spec: SYMMETRIC_DEFAULT
  Key Usage: ENCRYPT_DECRYPT
  Key Rotation: Enabled (Annual)
  
  Key Policy:
    - Allow root account full access
    - Allow cross-account access for EFS
    - Allow CloudTrail for audit logging
    - Deny key deletion without MFA

Key Access Control:
  Administrative Access:
    - Banking Infrastructure Team
    - Security Team
    - Compliance Team
  
  Usage Access:
    - EKS Service Accounts (IRSA)
    - Cross-account IAM roles
    - Application services
```

## Network Security

### Security Groups Configuration

#### EFS Security Groups

```yaml
CoreBank EFS Security Group:
  Name: sg-efs-corebank-secure
  Description: Secure EFS access with logging
  
  Inbound Rules:
    - Type: NFS (2049)
      Protocol: TCP
      Source: sg-eks-nodes-corebank
      Description: NFS from CoreBank EKS nodes
    - Type: NFS (2049)
      Protocol: TCP
      Source: sg-eks-nodes-satellite1
      Description: NFS from Satellite-1 EKS nodes
    - Type: NFS (2049)
      Protocol: TCP
      Source: sg-eks-nodes-satellite2
      Description: NFS from Satellite-2 EKS nodes
  
  Outbound Rules:
    - Type: All Traffic
      Protocol: All
      Destination: 0.0.0.0/0
      Description: All outbound (required for EFS)

  Security Features:
    - VPC Flow Logs: Enabled
    - CloudTrail Logging: Enabled
    - Security Group Rule Descriptions: Required
    - Automated Compliance Checking: Enabled
```

#### EKS Node Security Groups

```yaml
EKS Node Security Group (Enhanced):
  Name: sg-eks-nodes-secure
  Description: Secure EKS nodes with monitoring
  
  Inbound Rules:
    - Type: All Traffic
      Protocol: All
      Source: sg-eks-nodes-secure
      Description: Inter-node communication
    - Type: HTTPS (443)
      Protocol: TCP
      Source: sg-eks-cluster
      Description: Cluster API communication
    - Type: Custom TCP (10250)
      Protocol: TCP
      Source: sg-eks-cluster
      Description: Kubelet API
    - Type: Custom TCP (53)
      Protocol: TCP/UDP
      Source: 10.0.0.0/8
      Description: DNS resolution
  
  Outbound Rules:
    - Type: HTTPS (443)
      Protocol: TCP
      Destination: 0.0.0.0/0
      Description: Internet access for updates
    - Type: NFS (2049)
      Protocol: TCP
      Destination: sg-efs-corebank-secure
      Description: EFS access
    - Type: PostgreSQL (5432)
      Protocol: TCP
      Destination: sg-rds-secure
      Description: Database access
    - Type: Redis (6379)
      Protocol: TCP
      Destination: sg-elasticache-secure
      Description: Cache access

  Security Enhancements:
    - Instance Metadata Service: IMDSv2 only
    - Session Manager: Enabled for secure access
    - Systems Manager: Patch management enabled
    - CloudWatch Agent: Security monitoring enabled
```

### Network Access Control Lists (NACLs)

```yaml
Banking Subnet NACL (Restrictive):
  Inbound Rules:
    100: Allow HTTPS (443) from Corporate IP ranges
    110: Allow SSH (22) from Bastion hosts only
    120: Allow NFS (2049) from trusted subnets
    130: Allow PostgreSQL (5432) from app subnets
    140: Allow Redis (6379) from app subnets
    150: Allow Ephemeral (1024-65535) from trusted networks
    200: Allow ICMP from VPC CIDR (for troubleshooting)
    32767: Deny All from 0.0.0.0/0

  Outbound Rules:
    100: Allow HTTPS (443) to 0.0.0.0/0
    110: Allow NFS (2049) to EFS subnets
    120: Allow PostgreSQL (5432) to DB subnets
    130: Allow Redis (6379) to Cache subnets
    140: Allow DNS (53) to 0.0.0.0/0
    150: Allow Ephemeral (1024-65535) to 0.0.0.0/0
    32767: Deny All to 0.0.0.0/0

  Security Features:
    - Flow Log Analysis: Automated anomaly detection
    - Rule Validation: Automated compliance checking
    - Change Tracking: All changes logged and approved
    - Regular Review: Monthly access pattern analysis
```

## Application Security

### Container Security

#### 1. Image Security

```yaml
Container Image Security:
  Base Images:
    - Use minimal base images (Alpine, Distroless)
    - Regular security scanning with Trivy/Clair
    - Automated vulnerability patching
    - Image signing with Cosign

  Build Security:
    - Multi-stage builds to reduce attack surface
    - Non-root user execution
    - Read-only root filesystem
    - Security context constraints

  Registry Security:
    - Private ECR repositories
    - Image scanning on push
    - Lifecycle policies for old images
    - Access logging and monitoring
```

#### 2. Runtime Security

```yaml
Pod Security Standards:
  Security Context:
    runAsNonRoot: true
    runAsUser: 1001
    runAsGroup: 1001
    fsGroup: 1001
    readOnlyRootFilesystem: true
    allowPrivilegeEscalation: false
    
  Capabilities:
    drop: ["ALL"]
    add: [] # No additional capabilities
    
  Security Policies:
    - Pod Security Standards: Restricted
    - Network Policies: Enabled
    - Service Mesh: Istio with mTLS
    - Admission Controllers: OPA Gatekeeper

Runtime Monitoring:
  - Falco for runtime security monitoring
  - Sysdig for container behavior analysis
  - Twistlock for compliance scanning
  - Custom security metrics and alerting
```

### API Security

#### 1. Authentication and Authorization

```yaml
API Security Framework:
  Authentication:
    - JWT tokens with short expiration
    - Mutual TLS (mTLS) for service-to-service
    - OAuth 2.0 with PKCE for external APIs
    - Multi-factor authentication for admin APIs

  Authorization:
    - Role-Based Access Control (RBAC)
    - Attribute-Based Access Control (ABAC)
    - Policy-as-Code with Open Policy Agent
    - Fine-grained permissions per endpoint

  API Gateway Security:
    - Rate limiting and throttling
    - Request/response validation
    - SQL injection protection
    - Cross-site scripting (XSS) prevention
```

#### 2. API Monitoring and Protection

```yaml
API Protection:
  Web Application Firewall (WAF):
    - OWASP Top 10 protection
    - Custom rules for banking APIs
    - Geo-blocking for restricted regions
    - Bot protection and CAPTCHA

  API Monitoring:
    - Real-time API call monitoring
    - Anomaly detection for unusual patterns
    - Failed authentication tracking
    - Performance and availability monitoring

  Compliance:
    - PCI DSS API security requirements
    - GDPR data protection compliance
    - Banking regulation compliance
    - Regular penetration testing
```

## Monitoring and Incident Response

### Security Monitoring

#### 1. Log Aggregation and Analysis

```yaml
Security Logging:
  CloudTrail:
    - All API calls logged
    - Multi-region logging
    - Log file integrity validation
    - Real-time event processing

  VPC Flow Logs:
    - All network traffic logged
    - Anomaly detection enabled
    - Automated threat detection
    - Integration with SIEM systems

  Application Logs:
    - Structured logging (JSON format)
    - Security event correlation
    - Failed authentication tracking
    - Data access auditing

  Log Retention:
    - Security logs: 7 years (compliance)
    - Audit logs: 7 years (regulatory)
    - Performance logs: 30 days
    - Debug logs: 7 days
```

#### 2. Security Metrics and Alerting

```yaml
Security Metrics:
  Authentication Metrics:
    - Failed login attempts
    - Unusual login patterns
    - Privilege escalation attempts
    - Account lockouts

  Network Security Metrics:
    - Blocked connection attempts
    - Unusual traffic patterns
    - Port scanning detection
    - DDoS attack indicators

  Data Access Metrics:
    - Unauthorized access attempts
    - Data exfiltration indicators
    - Unusual file access patterns
    - Cross-account access anomalies

Alerting Configuration:
  Critical Alerts (Immediate):
    - Security breach indicators
    - Unauthorized root access
    - Data exfiltration attempts
    - System compromise indicators

  High Priority Alerts (15 minutes):
    - Multiple failed authentications
    - Unusual network traffic
    - Policy violations
    - Compliance failures

  Medium Priority Alerts (1 hour):
    - Security configuration changes
    - New user accounts created
    - Permission changes
    - Resource access anomalies
```

### Incident Response

#### 1. Automated Response

```yaml
Automated Security Responses:
  Account Compromise:
    - Automatic account lockout
    - Session termination
    - Access key rotation
    - Security team notification

  Network Attacks:
    - Automatic IP blocking
    - Security group updates
    - Traffic rerouting
    - DDoS mitigation activation

  Data Access Violations:
    - Access revocation
    - Data access logging
    - Compliance team notification
    - Forensic data collection

  Malware Detection:
    - Container isolation
    - Network segmentation
    - Malware signature updates
    - System quarantine
```

#### 2. Incident Response Procedures

```yaml
Incident Response Workflow:
  Detection:
    - Automated monitoring systems
    - Security team analysis
    - User reports
    - Third-party notifications

  Analysis:
    - Incident classification
    - Impact assessment
    - Root cause analysis
    - Evidence collection

  Containment:
    - Immediate threat isolation
    - System quarantine
    - Access revocation
    - Communication protocols

  Recovery:
    - System restoration
    - Data recovery
    - Security hardening
    - Monitoring enhancement

  Lessons Learned:
    - Post-incident review
    - Process improvements
    - Security updates
    - Training updates
```

## Compliance and Governance

### Regulatory Compliance

#### 1. Banking Regulations

```yaml
Compliance Framework:
  PCI DSS Level 1:
    - Cardholder data protection
    - Secure network architecture
    - Access control measures
    - Regular security testing

  ISO 27001:
    - Information security management
    - Risk assessment procedures
    - Security control implementation
    - Continuous improvement

  SOC 2 Type II:
    - Security controls audit
    - Availability controls
    - Processing integrity
    - Confidentiality measures

  Local Banking Regulations:
    - Data residency requirements
    - Audit trail maintenance
    - Incident reporting procedures
    - Customer data protection
```

#### 2. Compliance Monitoring

```yaml
Automated Compliance Checking:
  AWS Config Rules:
    - Encryption compliance
    - Access control validation
    - Network security verification
    - Resource configuration checks

  Security Hub:
    - Multi-standard compliance
    - Finding aggregation
    - Automated remediation
    - Compliance dashboards

  Custom Compliance Checks:
    - Banking-specific requirements
    - Cross-account access validation
    - Data classification compliance
    - Retention policy enforcement

Compliance Reporting:
  - Daily compliance status
  - Weekly trend analysis
  - Monthly compliance reports
  - Annual audit preparation
```

### Security Governance

#### 1. Security Policies

```yaml
Security Policy Framework:
  Access Control Policy:
    - Least privilege principle
    - Regular access reviews
    - Privileged access management
    - Multi-factor authentication

  Data Protection Policy:
    - Data classification standards
    - Encryption requirements
    - Data retention policies
    - Cross-border data transfer

  Incident Response Policy:
    - Response procedures
    - Communication protocols
    - Escalation procedures
    - Recovery processes

  Change Management Policy:
    - Security review requirements
    - Approval workflows
    - Testing procedures
    - Rollback plans
```

#### 2. Security Training and Awareness

```yaml
Security Training Program:
  Developer Security Training:
    - Secure coding practices
    - OWASP Top 10 awareness
    - Container security
    - API security best practices

  Operations Security Training:
    - Infrastructure security
    - Incident response procedures
    - Compliance requirements
    - Security tool usage

  General Security Awareness:
    - Phishing awareness
    - Social engineering prevention
    - Password security
    - Data handling procedures

Training Schedule:
  - Initial security training: All new employees
  - Annual refresher training: All employees
  - Specialized training: Role-specific
  - Incident-based training: As needed
```

This comprehensive security model provides multiple layers of protection while maintaining the flexibility and performance required for banking operations. Regular security assessments and updates ensure the model remains effective against evolving threats.
