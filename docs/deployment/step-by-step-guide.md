# Step-by-Step Deployment Guide

This guide provides detailed instructions for deploying the cross-account EFS solution.

## Prerequisites

### Required Tools

1. **AWS CLI** (v2.0+)
   ```bash
   curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
   unzip awscliv2.zip
   sudo ./aws/install
   ```

2. **kubectl** (v1.28+)
   ```bash
   curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
   sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
   ```

3. **eksctl** (v0.147+)
   ```bash
   curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
   sudo mv /tmp/eksctl /usr/local/bin
   ```

4. **Terraform** (v1.5+)
   ```bash
   wget https://releases.hashicorp.com/terraform/1.6.0/terraform_1.6.0_linux_amd64.zip
   unzip terraform_1.6.0_linux_amd64.zip
   sudo mv terraform /usr/local/bin/
   ```

### AWS Account Setup

1. **Create AWS Accounts**
   - CoreBank Account (Production)
   - Satellite Account 1 (Cards/Payments)
   - Satellite Account 2 (Loans/Deposits)

2. **Configure AWS CLI Profiles**
   ```bash
   aws configure --profile corebank
   aws configure --profile satellite-1
   aws configure --profile satellite-2
   ```

3. **Verify Access**
   ```bash
   aws sts get-caller-identity --profile corebank
   aws sts get-caller-identity --profile satellite-1
   aws sts get-caller-identity --profile satellite-2
   ```

## Phase 1: Environment Setup

### 1. Clone Repository

```bash
git clone https://github.com/vanhoangkha/mount-amazon-efs-file-systems-cross-account-from-amazon-eks.git
cd mount-amazon-efs-file-systems-cross-account-from-amazon-eks
```

### 2. Configure Environment

```bash
# Copy environment template
cp examples/environment.env.example .env

# Edit configuration
vim .env
```

Update the following variables:
```bash
COREBANK_ACCOUNT=YOUR_COREBANK_ACCOUNT_ID
SATELLITE1_ACCOUNT=YOUR_SATELLITE1_ACCOUNT_ID
SATELLITE2_ACCOUNT=YOUR_SATELLITE2_ACCOUNT_ID
AWS_REGION=ap-southeast-1
```

### 3. Load Configuration

```bash
source .env
```

## Phase 2: Network Infrastructure

### 1. Deploy VPCs

```bash
# Deploy CoreBank VPC
./scripts/01-deploy-networking.sh corebank

# Deploy Satellite VPCs
./scripts/01-deploy-networking.sh satellite-1
./scripts/01-deploy-networking.sh satellite-2
```

### 2. Setup VPC Peering

```bash
./scripts/setup-vpc-peering.sh
```

### 3. Verify Network Connectivity

```bash
# Test connectivity between VPCs
./scripts/test-network-connectivity.sh
```

## Phase 3: EKS Clusters

### 1. Deploy EKS Clusters

```bash
# Deploy CoreBank EKS cluster
./scripts/02-deploy-eks-clusters.sh corebank

# Deploy Satellite EKS clusters
./scripts/02-deploy-eks-clusters.sh satellite-1
./scripts/02-deploy-eks-clusters.sh satellite-2
```

### 2. Configure kubectl

```bash
# Update kubeconfig for all clusters
aws eks update-kubeconfig --region $AWS_REGION --name corebank-cluster --profile corebank
aws eks update-kubeconfig --region $AWS_REGION --name satellite-1-cluster --profile satellite-1
aws eks update-kubeconfig --region $AWS_REGION --name satellite-2-cluster --profile satellite-2
```

### 3. Verify EKS Clusters

```bash
# Check cluster status
kubectl get nodes --context corebank-cluster
kubectl get nodes --context satellite-1-cluster
kubectl get nodes --context satellite-2-cluster
```

## Phase 4: Storage Infrastructure

### 1. Deploy EFS File Systems

```bash
# Deploy CoreBank EFS (shared)
./scripts/03-deploy-efs-storage.sh corebank

# Deploy Satellite local EFS
./scripts/03-deploy-efs-storage.sh satellite-1
./scripts/03-deploy-efs-storage.sh satellite-2
```

### 2. Setup Cross-Account Access

```bash
./scripts/04-setup-cross-account-access.sh
```

### 3. Test EFS Connectivity

```bash
# Test EFS mount from each cluster
./scripts/test-efs-connectivity.sh
```

## Phase 5: Database Infrastructure

### 1. Deploy RDS Database

```bash
# Deploy PostgreSQL database in CoreBank account
./scripts/deploy-rds.sh
```

### 2. Deploy ElastiCache

```bash
# Deploy Redis cluster in CoreBank account
./scripts/deploy-elasticache.sh
```

### 3. Test Database Connectivity

```bash
./scripts/test-database-connectivity.sh
```

## Phase 6: Application Deployment

### 1. Build Application Images

```bash
# Build CoreBank application
cd applications/corebank
docker build -t corebank-app:latest .
docker tag corebank-app:latest $COREBANK_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com/corebank-app:latest

# Build Satellite application
cd ../satellite
docker build -t satellite-app:latest .
docker tag satellite-app:latest $SATELLITE1_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com/satellite-app:latest
```

### 2. Push Images to ECR

```bash
# Login to ECR
aws ecr get-login-password --region $AWS_REGION --profile corebank | docker login --username AWS --password-stdin $COREBANK_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com

# Push images
docker push $COREBANK_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com/corebank-app:latest
docker push $SATELLITE1_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com/satellite-app:latest
```

### 3. Deploy Applications

```bash
./scripts/05-deploy-applications.sh
```

### 4. Verify Application Deployment

```bash
# Check pod status
kubectl get pods -n banking --context corebank-cluster
kubectl get pods -n banking --context satellite-1-cluster
kubectl get pods -n banking --context satellite-2-cluster
```

## Phase 7: Monitoring Setup

### 1. Deploy Monitoring Infrastructure

```bash
./scripts/06-setup-monitoring.sh
```

### 2. Configure CloudWatch Dashboards

```bash
./scripts/setup-cloudwatch-dashboards.sh
```

### 3. Setup Alerting

```bash
./scripts/setup-alerting.sh
```

## Phase 8: Testing and Validation

### 1. Health Checks

```bash
./scripts/health-check.sh
```

### 2. Performance Testing

```bash
./scripts/performance-test.sh
```

### 3. Dual-Write Testing

```bash
./scripts/test-dual-write.sh
```

### 4. Failover Testing

```bash
./scripts/test-failover.sh
```

## Phase 9: Security Hardening

### 1. Security Scan

```bash
./scripts/security-scan.sh
```

### 2. Compliance Check

```bash
./scripts/compliance-check.sh
```

### 3. Penetration Testing

```bash
# Run automated security tests
./scripts/security-tests.sh
```

## Phase 10: Production Readiness

### 1. Backup Verification

```bash
./scripts/verify-backups.sh
```

### 2. Disaster Recovery Test

```bash
./scripts/test-disaster-recovery.sh
```

### 3. Documentation Review

```bash
# Generate deployment report
./scripts/generate-deployment-report.sh
```

## Post-Deployment Tasks

### 1. Monitoring Setup

- Configure CloudWatch alarms
- Set up SNS notifications
- Create Grafana dashboards
- Configure log aggregation

### 2. Operational Procedures

- Document runbooks
- Set up on-call procedures
- Create troubleshooting guides
- Establish change management process

### 3. Performance Optimization

- Monitor performance metrics
- Optimize resource allocation
- Fine-tune auto-scaling
- Review cost optimization

## Troubleshooting Common Issues

### EKS Cluster Issues

```bash
# Check cluster status
eksctl get cluster --region $AWS_REGION

# Check node group status
eksctl get nodegroup --cluster corebank-cluster --region $AWS_REGION

# Check pod logs
kubectl logs -f deployment/corebank-app -n banking
```

### EFS Mount Issues

```bash
# Check EFS mount targets
aws efs describe-mount-targets --file-system-id fs-xxxxxxxxx

# Test NFS connectivity
telnet fs-xxxxxxxxx.efs.$AWS_REGION.amazonaws.com 2049

# Check security groups
aws ec2 describe-security-groups --group-ids sg-xxxxxxxxx
```

### Cross-Account Access Issues

```bash
# Test IAM role assumption
aws sts assume-role --role-arn arn:aws:iam::ACCOUNT:role/ROLE --role-session-name test

# Check EFS resource policy
aws efs describe-file-system-policy --file-system-id fs-xxxxxxxxx
```

### Performance Issues

```bash
# Check EFS performance metrics
aws cloudwatch get-metric-statistics \
  --namespace AWS/EFS \
  --metric-name ThroughputUtilization \
  --dimensions Name=FileSystemId,Value=fs-xxxxxxxxx \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Average
```

## Rollback Procedures

### 1. Application Rollback

```bash
# Rollback to previous version
kubectl rollout undo deployment/corebank-app -n banking
kubectl rollout undo deployment/satellite-app -n banking
```

### 2. Infrastructure Rollback

```bash
# Rollback Terraform changes
terraform plan -destroy
terraform apply -destroy
```

### 3. Data Recovery

```bash
# Restore from EFS backup
aws backup start-restore-job \
  --recovery-point-arn arn:aws:backup:region:account:recovery-point:backup-vault-name/recovery-point-id \
  --metadata file://restore-metadata.json
```

## Maintenance Procedures

### 1. Regular Updates

- Update EKS cluster version
- Update node group AMIs
- Update application images
- Update Terraform modules

### 2. Security Updates

- Rotate IAM credentials
- Update security groups
- Patch vulnerabilities
- Review access permissions

### 3. Performance Tuning

- Monitor resource utilization
- Optimize EFS throughput
- Tune database parameters
- Adjust auto-scaling policies

This completes the step-by-step deployment guide. For additional support, refer to the troubleshooting documentation or create an issue in the GitHub repository.
