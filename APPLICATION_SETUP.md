# EFS Cross-Account Application Setup - Quick Start Guide

This guide will help you deploy and test the EFS cross-account applications I've created for you.

## 📋 What I've Created

I've built a complete solution with:

### 🐍 Python Flask Applications (`/applications/efs-test-app/`)
- **Simple REST API** for testing EFS operations
- **Cross-account EFS access** capabilities
- **Real-time file sharing** between accounts
- **Health monitoring** and performance metrics

### ☸️ Kubernetes Manifests (`/kubernetes/`)
- **CoreBank deployment** - runs in your CoreBank account
- **Satellite deployment** - runs in your Satellite account with cross-account EFS access
- **LoadBalancer services** for external access

### 🔧 Deployment Scripts (`/scripts/`)
- **`build-and-push-image.sh`** - Builds Docker images and pushes to ECR
- **`deploy-efs-test-app.sh`** - Deploys applications to EKS clusters
- **`test-efs-cross-account.sh`** - Comprehensive testing suite

## 🚀 How to Deploy and Test

### Step 1: Verify Prerequisites
Make sure you have the existing infrastructure scripts working:
```bash
# Check if your accounts are configured
aws sts get-caller-identity --profile corebank
aws sts get-caller-identity --profile satellite

# Ensure kubectl and docker are installed
kubectl version --client
docker --version
```

### Step 2: Deploy Infrastructure (if not already done)
```bash
# Deploy EKS clusters and EFS infrastructure
./scripts/deploy-infrastructure.sh
```

### Step 3: Build and Deploy Applications
```bash
# Build Docker images and push to ECR
./scripts/build-and-push-image.sh

# Deploy applications to both clusters
./scripts/deploy-efs-test-app.sh
```

### Step 4: Test Cross-Account Functionality
```bash
# Run comprehensive test suite
./scripts/test-efs-cross-account.sh
```

## 🧪 What the Applications Do

### CoreBank Application
- Runs in your CoreBank EKS cluster
- **Direct access** to CoreBank EFS
- Provides REST API for file operations
- Writes files to `/mnt/efs` (CoreBank EFS root)

### Satellite Application  
- Runs in your Satellite EKS cluster
- **Cross-account access** to CoreBank EFS via access points
- Same REST API interface
- Writes files to `/mnt/efs` (mapped to CoreBank EFS `/satellite` directory)

## 📡 API Endpoints

Both applications expose identical APIs:

```bash
# Health check
curl http://your-app-endpoint/health

# Write a file
curl -X POST -H "Content-Type: application/json" \
  -d '{
    "filename": "transactions/tx-001.json",
    "content": "Transaction data here",
    "metadata": {"amount": 1000, "type": "transfer"}
  }' \
  http://your-app-endpoint/write

# Read a file
curl "http://your-app-endpoint/read?filename=transactions/tx-001.json"

# List all files
curl http://your-app-endpoint/list

# Get statistics
curl http://your-app-endpoint/stats

# Run automated tests
curl -X POST http://your-app-endpoint/test
```

## 🔄 Cross-Account Data Sharing

The key feature is **real-time data sharing**:

1. **CoreBank writes** → **Satellite immediately sees the file**
2. **Satellite writes** → **CoreBank immediately sees the file**
3. **No data duplication** - single source of truth in CoreBank EFS
4. **Strong consistency** - no eventual consistency delays

## 📊 Testing Scenarios

The test suite validates:

✅ **Health Checks** - Both apps are running and EFS is mounted  
✅ **Write Operations** - Files can be written to EFS  
✅ **Read Operations** - Files can be read from EFS  
✅ **Cross-Account Consistency** - Files written by one app are readable by the other  
✅ **Performance** - Operations complete within acceptable timeframes  
✅ **File Listing** - Directory operations work correctly  

## 🔍 Monitoring and Troubleshooting

### Check Application Status
```bash
# Check pods
kubectl get pods -n efs-test

# Check services and endpoints
kubectl get svc -n efs-test

# View logs
kubectl logs -n efs-test -l app=efs-test-app --tail=50
```

### Check EFS Mount Status
```bash
# Exec into a pod to check mount
kubectl exec -n efs-test deployment/efs-test-app-corebank -- df -h /mnt/efs
kubectl exec -n efs-test deployment/efs-test-app-corebank -- ls -la /mnt/efs
```

### Application Logs
The applications provide detailed logging:
- EFS health check results
- File operation performance metrics
- Cross-account access status
- Error details for troubleshooting

## 🏗️ Architecture Benefits

### For Banking/Financial Applications:
1. **Centralized Data Storage** - All data in CoreBank account for compliance
2. **Real-time Access** - Satellite services get instant access to shared data
3. **Cost Efficient** - No data replication across accounts
4. **Security Compliant** - Cross-account access via IAM roles and EFS access points
5. **High Performance** - Provisioned throughput EFS for consistent performance

### Technical Benefits:
- **Kubernetes Native** - Standard K8s deployments with persistent volumes
- **Container Ready** - Lightweight Flask apps in Docker containers
- **Cloud Native** - Uses AWS EFS CSI driver and LoadBalancer services
- **Observable** - Built-in health checks, metrics, and logging

## 🎯 Use Cases

This solution is perfect for:

- **Transaction Processing** - Shared transaction logs across services
- **Document Management** - Centralized document storage with multi-service access
- **Configuration Sharing** - Shared configuration files across environments
- **Audit Logging** - Centralized audit trails accessible by compliance services
- **Data Pipeline** - Shared data processing between different service accounts

## 📁 File Structure Created

```
/applications/
├── efs-test-app/
│   ├── app.py              # Main Flask application
│   ├── requirements.txt    # Python dependencies
│   ├── Dockerfile         # Container definition
│   └── README.md          # Application documentation
└── README.md              # Application overview

/kubernetes/
├── corebank-app.yaml      # CoreBank deployment manifests
└── satellite-app.yaml     # Satellite deployment manifests

/scripts/
├── build-and-push-image.sh    # Docker build and ECR push
├── deploy-efs-test-app.sh      # K8s deployment script  
└── test-efs-cross-account.sh   # Comprehensive test suite
```

## 🎉 Next Steps

After successful deployment:

1. **Access your applications** via the LoadBalancer endpoints
2. **Test file operations** using the API endpoints
3. **Monitor performance** through the `/stats` endpoint
4. **Scale up/down** by adjusting replica counts in the manifests
5. **Add custom logic** to the Flask applications for your specific use cases

The applications provide a solid foundation for building banking-grade cross-account data sharing solutions on AWS EKS with EFS!
