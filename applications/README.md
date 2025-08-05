# EFS Cross-Account Test Applications

This directory contains simple Flask applications designed to test cross-account EFS functionality between AWS accounts.

## Application Structure

### `/applications/efs-test-app/`
- **`app.py`**: Main Flask application with REST API endpoints
- **`requirements.txt`**: Python dependencies
- **`Dockerfile`**: Container image definition

### `/kubernetes/`
- **`corebank-app.yaml`**: Kubernetes manifests for CoreBank application
- **`satellite-app.yaml`**: Kubernetes manifests for Satellite application

## API Endpoints

Each application exposes the following REST API endpoints:

### Health & Information
- `GET /` - Service information and API documentation
- `GET /health` - Health check with EFS connectivity test
- `GET /stats` - Application statistics and metrics

### File Operations
- `POST /write` - Write file to EFS
  ```json
  {
    "filename": "path/to/file.json",
    "content": "file content",
    "metadata": {"key": "value"}
  }
  ```
- `GET /read?filename=path/to/file.json` - Read file from EFS
- `GET /list` - List all files in EFS

### Testing
- `POST /test` - Run automated test suite

## Key Features

### Cross-Account EFS Access
- **CoreBank Application**: Accesses EFS directly in the same account
- **Satellite Application**: Accesses CoreBank EFS via cross-account access points

### Real-time Data Consistency
- Files written by one application are immediately visible to the other
- All applications write to the same shared EFS in the CoreBank account

### Performance Monitoring
- Built-in performance metrics collection
- Health checks with latency measurements
- Comprehensive logging and error handling

### Banking-Grade Security
- Uses EFS access points for granular access control
- Cross-account IAM roles with least privilege permissions
- Encrypted data at rest and in transit

## Deployment

### Prerequisites
1. EKS clusters deployed in both accounts
2. EFS infrastructure with cross-account access configured
3. Docker images built and pushed to ECR

### Quick Deployment
```bash
# Deploy all applications
./scripts/deploy-efs-test-app.sh

# Test functionality
./scripts/test-efs-cross-account.sh
```

### Manual Deployment
```bash
# Build and push images
./scripts/build-and-push-image.sh

# Deploy to CoreBank
kubectl apply -f kubernetes/corebank-app.yaml

# Deploy to Satellite
kubectl apply -f kubernetes/satellite-app.yaml
```

## Testing Examples

### Health Check
```bash
curl http://your-endpoint/health
```

### Write File
```bash
curl -X POST -H "Content-Type: application/json" \
  -d '{
    "filename": "test/transaction.json",
    "content": "Transaction data",
    "metadata": {"amount": 1000, "currency": "USD"}
  }' \
  http://your-endpoint/write
```

### Read File
```bash
curl "http://your-endpoint/read?filename=test/transaction.json"
```

### List Files
```bash
curl http://your-endpoint/list
```

### Run Automated Tests
```bash
curl -X POST http://your-endpoint/test
```

## Architecture Benefits

### For Banking/Financial Services
1. **Real-time Data Sharing**: Instant data availability across accounts
2. **Compliance**: Centralized data storage for audit requirements
3. **Cost Efficiency**: No data duplication across accounts
4. **Simplified Architecture**: Single source of truth for data

### Performance Characteristics
- **Write Latency**: < 30 seconds for cross-account writes
- **Read Latency**: < 5 seconds for cross-account reads  
- **Consistency**: Strong consistency across all accounts
- **Throughput**: Provisioned throughput (1000 MiB/s) for predictable performance

## Monitoring

### Application Metrics
- Write/read operation counts and latencies
- Error rates and success rates
- System resource utilization
- EFS mount health status

### CloudWatch Integration
- Custom metrics automatically sent to CloudWatch
- Built-in alarms for critical issues
- Comprehensive logging for troubleshooting

## Troubleshooting

### Common Issues

1. **EFS Mount Failures**
   ```bash
   # Check pod logs
   kubectl logs -n efs-test deployment/efs-test-app-corebank
   
   # Verify EFS CSI driver
   kubectl get pods -n kube-system -l app=efs-csi-controller
   ```

2. **Cross-Account Access Issues**
   ```bash
   # Verify EFS resource policy
   aws efs describe-file-system-policy --file-system-id fs-xxxxx
   
   # Check IAM role permissions
   aws iam get-role-policy --role-name satellite-efs-cross-account-role --policy-name EFSCrossAccountAccess
   ```

3. **Application Health Issues**
   ```bash
   # Check service endpoints
   kubectl get svc -n efs-test
   
   # View detailed pod information
   kubectl describe pod -n efs-test -l app=efs-test-app
   ```

### Log Analysis
```bash
# View real-time logs
kubectl logs -f -n efs-test deployment/efs-test-app-satellite

# Get logs from all replicas
kubectl logs -n efs-test -l app=efs-test-app --tail=100
```

## Security Notes

1. **Network Security**: Applications communicate with EFS over secure NFS (port 2049)
2. **Encryption**: All data encrypted at rest and in transit
3. **Access Control**: Fine-grained access via EFS access points
4. **IAM Roles**: Least privilege cross-account access roles
5. **Container Security**: Non-root containers with minimal attack surface

## Performance Tuning

### EFS Mount Options
The applications use optimized NFS mount options for banking workloads:
- `rsize=1048576,wsize=1048576` - Large buffer sizes
- `hard,intr` - Reliable operations with interrupt capability
- `timeo=600` - Extended timeout for network reliability

### Resource Limits
- **CPU**: 250m request, 500m limit
- **Memory**: 256Mi request, 512Mi limit
- **Storage**: Shared EFS with provisioned throughput

## Production Considerations

1. **Scaling**: Adjust replica counts based on load
2. **Backup**: EFS automatic backups enabled
3. **Monitoring**: CloudWatch dashboards for operational visibility
4. **Disaster Recovery**: Cross-region EFS replication available
5. **Compliance**: Audit logs retained for required period
