#!/usr/bin/env python3
"""
Dual Mount EFS Manager for Satellite Applications
Handles dual-write operations to both local and cross-account EFS
"""

import os
import asyncio
import aiofiles
import logging
import time
import json
from pathlib import Path
from typing import Dict, Optional, Tuple, List
from dataclasses import dataclass
from datetime import datetime
import boto3
from concurrent.futures import ThreadPoolExecutor

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

@dataclass
class WriteResult:
    """Result of a write operation"""
    success: bool
    duration: float
    bytes_written: int = 0
    error: Optional[str] = None

@dataclass
class HealthStatus:
    """Health status of a mount point"""
    healthy: bool
    latency_ms: float
    writable: bool
    readable: bool
    mount_path: str
    error: Optional[str] = None

class DualMountEFSManager:
    """Manager for dual EFS mount points with banking-grade reliability"""
    
    def __init__(self):
        # Configuration from environment
        self.local_mount = Path(os.getenv('LOCAL_EFS_PATH', '/mnt/efs-local'))
        self.corebank_mount = Path(os.getenv('COREBANK_EFS_PATH', '/mnt/efs-corebank'))
        self.sync_timeout = int(os.getenv('DUAL_WRITE_TIMEOUT', '60'))
        self.dual_write_enabled = os.getenv('DUAL_WRITE_ENABLED', 'true').lower() == 'true'
        self.batch_size = int(os.getenv('BATCH_SIZE', '100'))
        self.buffer_size = int(os.getenv('BUFFER_SIZE', '1048576'))  # 1MB
        
        # Performance tracking
        self.metrics = {
            'total_writes': 0,
            'successful_writes': 0,
            'failed_writes': 0,
            'avg_write_time': 0.0,
            'last_health_check': None
        }
        
        # Thread pool for I/O operations
        self.executor = ThreadPoolExecutor(max_workers=20)
        
        # CloudWatch client for metrics
        self.cloudwatch = boto3.client('cloudwatch', region_name=os.getenv('AWS_REGION', 'ap-southeast-1'))
        
        # Ensure directories exist
        self._ensure_directories()
        
        logger.info(f"Initialized DualMountEFSManager:")
        logger.info(f"  - Local EFS: {self.local_mount}")
        logger.info(f"  - CoreBank EFS: {self.corebank_mount}")
        logger.info(f"  - Sync timeout: {self.sync_timeout}s")
        logger.info(f"  - Dual write: {self.dual_write_enabled}")
    
    def _ensure_directories(self):
        """Ensure mount point directories exist"""
        try:
            self.local_mount.mkdir(parents=True, exist_ok=True)
            self.corebank_mount.mkdir(parents=True, exist_ok=True)
        except Exception as e:
            logger.error(f"Failed to create mount directories: {e}")
            raise
    
    async def health_check(self) -> Dict[str, any]:
        """Comprehensive health check for both mount points"""
        start_time = time.time()
        
        # Check both mount points concurrently
        local_task = asyncio.create_task(
            self._check_mount_health(self.local_mount, "local")
        )
        corebank_task = asyncio.create_task(
            self._check_mount_health(self.corebank_mount, "corebank")
        )
        
        try:
            local_health, corebank_health = await asyncio.gather(
                local_task, corebank_task, return_exceptions=True
            )
            
            # Handle exceptions
            if isinstance(local_health, Exception):
                local_health = HealthStatus(
                    healthy=False, latency_ms=0, writable=False, 
                    readable=False, mount_path=str(self.local_mount),
                    error=str(local_health)
                )
            
            if isinstance(corebank_health, Exception):
                corebank_health = HealthStatus(
                    healthy=False, latency_ms=0, writable=False,
                    readable=False, mount_path=str(self.corebank_mount),
                    error=str(corebank_health)
                )
            
            # Overall health status
            overall_healthy = local_health.healthy and corebank_health.healthy
            
            health_result = {
                "timestamp": datetime.now().isoformat(),
                "healthy": overall_healthy,
                "dual_write_enabled": self.dual_write_enabled,
                "local_efs": {
                    "healthy": local_health.healthy,
                    "latency_ms": local_health.latency_ms,
                    "writable": local_health.writable,
                    "readable": local_health.readable,
                    "mount_path": local_health.mount_path,
                    "error": local_health.error
                },
                "corebank_efs": {
                    "healthy": corebank_health.healthy,
                    "latency_ms": corebank_health.latency_ms,
                    "writable": corebank_health.writable,
                    "readable": corebank_health.readable,
                    "mount_path": corebank_health.mount_path,
                    "error": corebank_health.error
                },
                "metrics": self.metrics.copy()
            }
            
            # Update last health check time
            self.metrics['last_health_check'] = time.time()
            
            # Send metrics to CloudWatch
            await self._send_health_metrics(health_result)
            
            return health_result
            
        except Exception as e:
            logger.error(f"Health check failed: {e}")
            return {
                "timestamp": datetime.now().isoformat(),
                "healthy": False,
                "error": str(e),
                "dual_write_enabled": self.dual_write_enabled
            }
    
    async def _check_mount_health(self, mount_path: Path, mount_name: str) -> HealthStatus:
        """Check health of a specific mount point"""
        try:
            start_time = time.time()
            
            # Test file operations
            test_file = mount_path / f"health_check_{int(time.time())}.tmp"
            test_data = f"health_check_{mount_name}_{time.time()}"
            
            # Write test
            async with aiofiles.open(test_file, 'w', buffering=self.buffer_size) as f:
                await f.write(test_data)
                await f.fsync()
            
            # Read test
            async with aiofiles.open(test_file, 'r') as f:
                read_data = await f.read()
            
            # Verify data integrity
            if read_data != test_data:
                raise Exception("Data integrity check failed")
            
            # Cleanup
            test_file.unlink()
            
            end_time = time.time()
            latency = (end_time - start_time) * 1000  # Convert to milliseconds
            
            return HealthStatus(
                healthy=True,
                latency_ms=round(latency, 2),
                writable=True,
                readable=True,
                mount_path=str(mount_path)
            )
            
        except Exception as e:
            logger.error(f"Health check failed for {mount_name}: {e}")
            return HealthStatus(
                healthy=False,
                latency_ms=0,
                writable=False,
                readable=False,
                mount_path=str(mount_path),
                error=str(e)
            )
    
    async def write_data(self, filename: str, data: str, metadata: Dict = None) -> Dict[str, WriteResult]:
        """
        Dual-write data to both mount points with performance optimization
        """
        if not self.dual_write_enabled:
            # Single write to local only
            result = await self._write_to_mount(self.local_mount, filename, data, metadata)
            return {
                "local": result,
                "corebank": WriteResult(success=False, duration=0, error="Dual write disabled")
            }
        
        start_time = time.time()
        self.metrics['total_writes'] += 1
        
        try:
            # Start both writes concurrently
            local_task = asyncio.create_task(
                self._write_to_mount(self.local_mount, filename, data, metadata)
            )
            corebank_task = asyncio.create_task(
                self._write_to_mount(self.corebank_mount, filename, data, metadata)
            )
            
            # Wait for both writes with timeout
            results = await asyncio.wait_for(
                asyncio.gather(local_task, corebank_task, return_exceptions=True),
                timeout=self.sync_timeout
            )
            
            end_time = time.time()
            total_duration = end_time - start_time
            
            # Process results
            local_result = results[0] if not isinstance(results[0], Exception) else WriteResult(
                success=False, duration=0, error=str(results[0])
            )
            corebank_result = results[1] if not isinstance(results[1], Exception) else WriteResult(
                success=False, duration=0, error=str(results[1])
            )
            
            # Update metrics
            if local_result.success or corebank_result.success:
                self.metrics['successful_writes'] += 1
            else:
                self.metrics['failed_writes'] += 1
            
            # Update average write time
            self.metrics['avg_write_time'] = (
                (self.metrics['avg_write_time'] * (self.metrics['total_writes'] - 1) + total_duration) /
                self.metrics['total_writes']
            )
            
            # Log performance
            logger.info(f"Dual write completed in {total_duration:.2f}s - "
                       f"Local: {'✓' if local_result.success else '✗'}, "
                       f"CoreBank: {'✓' if corebank_result.success else '✗'}")
            
            # Send performance metrics
            await self._send_performance_metrics(total_duration, local_result.success, corebank_result.success)
            
            return {"local": local_result, "corebank": corebank_result}
            
        except asyncio.TimeoutError:
            error_msg = f"Dual write timeout after {self.sync_timeout}s"
            logger.error(error_msg)
            self.metrics['failed_writes'] += 1
            
            return {
                "local": WriteResult(success=False, duration=self.sync_timeout, error=error_msg),
                "corebank": WriteResult(success=False, duration=self.sync_timeout, error=error_msg)
            }
        except Exception as e:
            error_msg = f"Dual write error: {e}"
            logger.error(error_msg)
            self.metrics['failed_writes'] += 1
            
            return {
                "local": WriteResult(success=False, duration=0, error=error_msg),
                "corebank": WriteResult(success=False, duration=0, error=error_msg)
            }
    
    async def _write_to_mount(self, mount_path: Path, filename: str, data: str, metadata: Dict = None) -> WriteResult:
        """Write data to a specific mount point with optimization"""
        try:
            start_time = time.time()
            
            # Prepare file path
            file_path = mount_path / filename
            file_path.parent.mkdir(parents=True, exist_ok=True)
            
            # Prepare data with metadata
            if metadata:
                full_data = {
                    "timestamp": datetime.now().isoformat(),
                    "metadata": metadata,
                    "data": data
                }
                write_data = json.dumps(full_data, indent=2)
            else:
                write_data = data
            
            # Write file with optimized buffering
            async with aiofiles.open(file_path, 'w', buffering=self.buffer_size) as f:
                await f.write(write_data)
                await f.fsync()  # Force sync to EFS
            
            end_time = time.time()
            duration = end_time - start_time
            bytes_written = len(write_data.encode('utf-8'))
            
            return WriteResult(
                success=True,
                duration=duration,
                bytes_written=bytes_written
            )
            
        except Exception as e:
            logger.error(f"Write failed to {mount_path}: {e}")
            return WriteResult(success=False, duration=0, error=str(e))
    
    async def read_data(self, filename: str, from_mount: str = "local") -> Tuple[bool, Optional[str], Optional[str]]:
        """
        Read data from specified mount point
        Returns: (success, data, error)
        """
        try:
            if from_mount == "local":
                mount_path = self.local_mount
            elif from_mount == "corebank":
                mount_path = self.corebank_mount
            else:
                return False, None, f"Invalid mount: {from_mount}"
            
            file_path = mount_path / filename
            
            if not file_path.exists():
                return False, None, f"File not found: {filename}"
            
            async with aiofiles.open(file_path, 'r') as f:
                data = await f.read()
            
            return True, data, None
            
        except Exception as e:
            logger.error(f"Read failed from {from_mount}: {e}")
            return False, None, str(e)
    
    async def batch_write(self, files: List[Tuple[str, str, Dict]]) -> Dict:
        """
        Batch write multiple files with optimized performance
        """
        start_time = time.time()
        
        # Split into batches
        batches = [files[i:i + self.batch_size] for i in range(0, len(files), self.batch_size)]
        
        results = {
            "total_files": len(files),
            "successful_writes": 0,
            "failed_writes": 0,
            "batches_processed": 0,
            "errors": []
        }
        
        for batch in batches:
            batch_results = await self._process_batch(batch)
            results["successful_writes"] += batch_results["successful"]
            results["failed_writes"] += batch_results["failed"]
            results["batches_processed"] += 1
            results["errors"].extend(batch_results["errors"])
        
        end_time = time.time()
        results["total_duration"] = end_time - start_time
        results["throughput"] = len(files) / (end_time - start_time) if end_time > start_time else 0
        
        return results
    
    async def _process_batch(self, batch: List[Tuple[str, str, Dict]]) -> Dict:
        """Process a batch of files"""
        tasks = []
        
        for filename, data, metadata in batch:
            task = asyncio.create_task(self.write_data(filename, data, metadata))
            tasks.append(task)
        
        try:
            results = await asyncio.wait_for(
                asyncio.gather(*tasks, return_exceptions=True),
                timeout=self.sync_timeout
            )
            
            successful = 0
            failed = 0
            errors = []
            
            for result in results:
                if isinstance(result, Exception):
                    failed += 1
                    errors.append(str(result))
                elif result.get("local", {}).get("success") or result.get("corebank", {}).get("success"):
                    successful += 1
                else:
                    failed += 1
                    errors.append("Both local and corebank writes failed")
            
            return {
                "successful": successful,
                "failed": failed,
                "errors": errors
            }
            
        except asyncio.TimeoutError:
            return {
                "successful": 0,
                "failed": len(batch),
                "errors": ["Batch timeout exceeded"]
            }
    
    async def sync_missing_files(self) -> Dict[str, any]:
        """
        Sync files from local to corebank (recovery function)
        """
        try:
            start_time = time.time()
            synced_files = []
            errors = []
            
            # Get all files from local
            local_files = []
            for root, dirs, files in os.walk(self.local_mount):
                for file in files:
                    if not file.startswith('health_check_'):  # Skip health check files
                        rel_path = os.path.relpath(os.path.join(root, file), self.local_mount)
                        local_files.append(rel_path)
            
            # Check and sync missing files
            for rel_path in local_files:
                local_file = self.local_mount / rel_path
                corebank_file = self.corebank_mount / rel_path
                
                if not corebank_file.exists():
                    try:
                        # Read from local
                        async with aiofiles.open(local_file, 'r') as f:
                            data = await f.read()
                        
                        # Write to corebank
                        corebank_file.parent.mkdir(parents=True, exist_ok=True)
                        async with aiofiles.open(corebank_file, 'w', buffering=self.buffer_size) as f:
                            await f.write(data)
                            await f.fsync()
                        
                        synced_files.append(rel_path)
                        
                    except Exception as e:
                        errors.append(f"{rel_path}: {str(e)}")
            
            end_time = time.time()
            duration = end_time - start_time
            
            result = {
                "success": len(errors) == 0,
                "duration": duration,
                "synced_files": len(synced_files),
                "total_files": len(local_files),
                "files_synced": synced_files,
                "errors": errors
            }
            
            logger.info(f"Sync completed: {len(synced_files)} files synced in {duration:.2f}s")
            return result
            
        except Exception as e:
            logger.error(f"Sync failed: {e}")
            return {
                "success": False,
                "error": str(e),
                "synced_files": 0,
                "total_files": 0
            }
    
    async def _send_health_metrics(self, health_data: Dict):
        """Send health metrics to CloudWatch"""
        try:
            metrics = [
                {
                    'MetricName': 'LocalEFSHealth',
                    'Value': 1 if health_data['local_efs']['healthy'] else 0,
                    'Unit': 'Count'
                },
                {
                    'MetricName': 'CoreBankEFSHealth',
                    'Value': 1 if health_data['corebank_efs']['healthy'] else 0,
                    'Unit': 'Count'
                },
                {
                    'MetricName': 'LocalEFSLatency',
                    'Value': health_data['local_efs']['latency_ms'],
                    'Unit': 'Milliseconds'
                },
                {
                    'MetricName': 'CoreBankEFSLatency',
                    'Value': health_data['corebank_efs']['latency_ms'],
                    'Unit': 'Milliseconds'
                }
            ]
            
            self.cloudwatch.put_metric_data(
                Namespace='Banking/EFS',
                MetricData=metrics
            )
            
        except Exception as e:
            logger.error(f"Failed to send health metrics: {e}")
    
    async def _send_performance_metrics(self, duration: float, local_success: bool, corebank_success: bool):
        """Send performance metrics to CloudWatch"""
        try:
            metrics = [
                {
                    'MetricName': 'DualWriteLatency',
                    'Value': duration * 1000,  # Convert to milliseconds
                    'Unit': 'Milliseconds'
                },
                {
                    'MetricName': 'DualWriteSuccessRate',
                    'Value': 100 if (local_success or corebank_success) else 0,
                    'Unit': 'Percent'
                },
                {
                    'MetricName': 'LocalWriteSuccess',
                    'Value': 1 if local_success else 0,
                    'Unit': 'Count'
                },
                {
                    'MetricName': 'CoreBankWriteSuccess',
                    'Value': 1 if corebank_success else 0,
                    'Unit': 'Count'
                }
            ]
            
            self.cloudwatch.put_metric_data(
                Namespace='Banking/Performance',
                MetricData=metrics
            )
            
        except Exception as e:
            logger.error(f"Failed to send performance metrics: {e}")
    
    def get_metrics(self) -> Dict:
        """Get current performance metrics"""
        return self.metrics.copy()
    
    async def cleanup(self):
        """Cleanup resources"""
        self.executor.shutdown(wait=True)
        logger.info("DualMountEFSManager cleanup completed")
