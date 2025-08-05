# EFS Cross-Account Operations Guide

## 🎯 Quick Start

Your EFS cross-account file sharing solution is now deployed and validated. This guide covers common operational tasks.

## 📊 System Status Check

### Check Infrastructure Status
```bash
# Load environment variables
source ./efs-infrastructure.env
source ./app-endpoints.env

# Check EFS file system
aws efs describe-file-systems --file-system-id $EFS_COREBANK_ID --region $AWS_REGION

# Check access point
aws efs describe-access-points --access-point-ids $SATELLITE_ACCESS_POINT --region $AWS_REGION
```

### Check Application Health
```bash
# CoreBank application
curl http://$COREBANK_ENDPOINT/health | jq

# Satellite application
curl http://$SATELLITE_ENDPOINT/health | jq
```

## 📝 File Operations

### Writing Files

#### From CoreBank Application
```bash
curl -X POST -H 'Content-Type: application/json' \
  -d '{
    "filename": "corebank/document.json",
    "content": "Important CoreBank data",
    "metadata": {"department": "core", "type": "document"}
  }' \
  http://$COREBANK_ENDPOINT/write
```

#### From Satellite Application
```bash
curl -X POST -H 'Content-Type: application/json' \
  -d '{
    "filename": "reports/monthly_report.json",
    "content": "Satellite monthly report data",
    "metadata": {"department": "satellite", "type": "report"}
  }' \
  http://$SATELLITE_ENDPOINT/write
```

### Reading Files

#### Read from CoreBank
```bash
# Read file written by CoreBank
curl "http://$COREBANK_ENDPOINT/read?filename=corebank/document.json" | jq

# Read file written by Satellite (cross-account access)
curl "http://$COREBANK_ENDPOINT/read?filename=reports/monthly_report.json" | jq
```

#### Read from Satellite
```bash
# Read file written by Satellite
curl "http://$SATELLITE_ENDPOINT/read?filename=reports/monthly_report.json" | jq

# Note: Satellite can only read files within its access point scope
```

### Listing Files

#### List from CoreBank (all directories)
```bash
curl "http://$COREBANK_ENDPOINT/list" | jq
curl "http://$COREBANK_ENDPOINT/list?path=corebank" | jq
curl "http://$COREBANK_ENDPOINT/list?path=satellite" | jq
```

#### List from Satellite (restricted scope)
```bash
curl "http://$SATELLITE_ENDPOINT/list" | jq
curl "http://$SATELLITE_ENDPOINT/list?path=reports" | jq
```

## 🔍 Monitoring and Debugging

### Application Logs
```bash
# CoreBank application logs
kubectl logs -n efs-test -l app=efs-test-app --context corebank-cluster --tail=50

# Satellite application logs
kubectl logs -n efs-test -l app=efs-test-app --context satellite-cluster --tail=50
```

### EFS CSI Driver Logs
```bash
# CoreBank EFS CSI driver
kubectl logs -n kube-system -l app=efs-csi-controller --context corebank-cluster --tail=20

# Satellite EFS CSI driver
kubectl logs -n kube-system -l app=efs-csi-controller --context satellite-cluster --tail=20
```

### Pod Status and Mounts
```bash
# Check pod status
kubectl get pods -n efs-test --context corebank-cluster
kubectl get pods -n efs-test --context satellite-cluster

# Check mount status
kubectl exec -n efs-test -l app=efs-test-app --context corebank-cluster -- df -h
kubectl exec -n efs-test -l app=efs-test-app --context satellite-cluster -- df -h

# Test write permissions
kubectl exec -n efs-test -l app=efs-test-app --context corebank-cluster -- touch /mnt/efs-corebank/test-core.txt
kubectl exec -n efs-test -l app=efs-test-app --context satellite-cluster -- touch /mnt/efs-corebank/test-satellite.txt
```

## 🧪 Testing and Validation

### Run Automated Test Suites
```bash
# CoreBank test suite
curl -X POST http://$COREBANK_ENDPOINT/test | jq

# Satellite test suite
curl -X POST http://$SATELLITE_ENDPOINT/test | jq
```

### Manual Cross-Account Test
```bash
# 1. Write from Satellite
SHARED_FILE="shared/cross-test-$(date +%s).json"
curl -X POST -H 'Content-Type: application/json' \
  -d "{
    \"filename\": \"$SHARED_FILE\",
    \"content\": \"Cross-account test at $(date)\",
    \"metadata\": {\"test\": \"cross-account\", \"timestamp\": \"$(date -Iseconds)\"}
  }" \
  http://$SATELLITE_ENDPOINT/write

# 2. Read from CoreBank
sleep 2
curl "http://$COREBANK_ENDPOINT/read?filename=$SHARED_FILE" | jq
```

### Performance Testing
```bash
# Test write performance
for i in {1..10}; do
  time curl -X POST -H 'Content-Type: application/json' \
    -d "{\"filename\":\"perf/test-$i.json\",\"content\":\"Performance test $i\"}" \
    http://$COREBANK_ENDPOINT/write
done

# Test read performance
for i in {1..10}; do
  time curl "http://$COREBANK_ENDPOINT/read?filename=perf/test-$i.json" > /dev/null
done
```

## 🚨 Troubleshooting

### Common Issues

#### 1. Application Not Responding
```bash
# Check pod status
kubectl get pods -n efs-test --context corebank-cluster
kubectl describe pods -n efs-test --context corebank-cluster -l app=efs-test-app

# Check service status
kubectl get svc -n efs-test --context corebank-cluster
```

#### 2. EFS Mount Issues
```bash
# Check PVC status
kubectl get pvc -n efs-test --context corebank-cluster
kubectl describe pvc efs-corebank-pvc -n efs-test --context corebank-cluster

# Check EFS CSI driver
kubectl get pods -n kube-system -l app=efs-csi-controller --context corebank-cluster
```

#### 3. Cross-Account Access Denied
```bash
# Check IAM role
aws iam get-role --role-name satellite-EFS-CrossAccount-Role

# Check EFS resource policy
aws efs describe-file-system-policy --file-system-id $EFS_COREBANK_ID --region $AWS_REGION

# Check access point
aws efs describe-access-points --access-point-ids $SATELLITE_ACCESS_POINT --region $AWS_REGION
```

#### 4. Network Connectivity Issues
```bash
# Check security group rules
aws ec2 describe-security-groups --group-ids $EFS_SG_ID --region $AWS_REGION

# Test network connectivity from pods
kubectl exec -n efs-test -l app=efs-test-app --context satellite-cluster -- nslookup $EFS_COREBANK_ID.efs.$AWS_REGION.amazonaws.com
```

### Recovery Procedures

#### Restart Applications
```bash
# Restart CoreBank deployment
kubectl rollout restart deployment/efs-test-app -n efs-test --context corebank-cluster

# Restart Satellite deployment
kubectl rollout restart deployment/efs-test-app -n efs-test --context satellite-cluster
```

#### Recreate EFS Mounts
```bash
# Delete and recreate PVC (CoreBank)
kubectl delete pvc efs-corebank-pvc -n efs-test --context corebank-cluster
kubectl apply -f /tmp/corebank-efs-test-app.yaml

# Delete and recreate PVC (Satellite)
kubectl delete pvc efs-corebank-pvc -n efs-test --context satellite-cluster
kubectl apply -f /tmp/satellite-efs-test-app.yaml
```

## 📈 Scaling Operations

### Horizontal Scaling
```bash
# Scale CoreBank application
kubectl scale deployment efs-test-app -n efs-test --context corebank-cluster --replicas=4

# Scale Satellite application
kubectl scale deployment efs-test-app -n efs-test --context satellite-cluster --replicas=2

# Check HPA status
kubectl get hpa -n efs-test --context corebank-cluster
kubectl get hpa -n efs-test --context satellite-cluster
```

### EFS Performance Scaling
```bash
# Increase EFS throughput
aws efs modify-file-system \
  --file-system-id $EFS_COREBANK_ID \
  --provisioned-throughput-in-mibps 2000 \
  --region $AWS_REGION
```

## 🔐 Security Operations

### Rotate IAM Roles
```bash
# Update IAM role policy
aws iam put-role-policy \
  --role-name satellite-EFS-CrossAccount-Role \
  --policy-name EFS-CrossAccount-Access-Policy \
  --policy-document file://updated-policy.json
```

### Update Access Point Permissions
```bash
# Note: Access point permissions cannot be modified after creation
# If changes are needed, create a new access point and update the deployment
```

### Security Audit
```bash
# Check EFS resource policy
aws efs describe-file-system-policy --file-system-id $EFS_COREBANK_ID --region $AWS_REGION

# Check IAM roles
aws iam list-roles --query 'Roles[?contains(RoleName, `EFS`)]'

# Check security groups
aws ec2 describe-security-groups --group-ids $EFS_SG_ID --region $AWS_REGION
```

## 📊 Monitoring Setup

### CloudWatch Metrics
```bash
# EFS metrics
aws cloudwatch get-metric-statistics \
  --namespace AWS/EFS \
  --metric-name ClientConnections \
  --dimensions Name=FileSystemId,Value=$EFS_COREBANK_ID \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Average \
  --region $AWS_REGION
```

### Application Metrics
```bash
# Get application statistics
curl http://$COREBANK_ENDPOINT/stats | jq
curl http://$SATELLITE_ENDPOINT/stats | jq
```

## 🎯 Best Practices

### File Organization
- **CoreBank files**: Store in `/corebank/` directory
- **Satellite files**: Store in `/satellite/` directory (via access point)
- **Shared files**: Use `/shared/` directory for cross-account access
- **Temporary files**: Use `/tmp/` directory for short-term storage

### Performance Optimization
- Use appropriate file sizes (avoid very small files)
- Implement proper caching strategies
- Monitor EFS performance metrics
- Consider EFS Intelligent Tiering for cost optimization

### Security Guidelines
- Regularly review IAM policies and access patterns
- Use encryption in transit for sensitive data
- Implement proper logging and audit trails
- Follow principle of least privilege

---

**Last Updated**: $(date)
**Next Review**: $(date -d '+30 days')
