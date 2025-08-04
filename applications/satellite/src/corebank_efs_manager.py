#!/usr/bin/env python3
"""
CoreBank EFS Manager for Satellite Applications
Handles operations to shared CoreBank EFS across accounts
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

class CoreBankEFSManager:
    """Manager for CoreBank EFS mount with banking-grade reliability"""
    
    def __init__(self):
        # Configuration from environment
        self.corebank_mount = Path(os.getenv('COREBANK_EFS_PATH', '/mnt/efs-corebank'))
        self.write_timeout = int(os.getenv('WRITE_TIMEOUT', '30'))
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
        
        logger.info(f"Initialized CoreBankEFSManager:")
        logger.info(f"  - CoreBank EFS: {self.corebank_mount}")
        logger.info(f"  - Write timeout: {self.write_timeout}s")
    
    def _ensure_directories(self):
        """Ensure mount point directories exist"""
        try:
            self.corebank_mount.mkdir(parents=True, exist_ok=True)
        except Exception as e:
            logger.error(f"Failed to create mount directories: {e}")
            raise
    
    async def health_check(self) -> Dict[str, any]:
        """Health check for CoreBank EFS mount"""
        start_time = time.time()
        
        try:
            corebank_health = await self._check_mount_health(self.corebank_mount, "corebank")
            
            # Handle exceptions
            if isinstance(corebank_health, Exception):
                corebank_health = HealthStatus(
                    healthy=False, latency_ms=0, writable=False,
                    readable=False, mount_path=str(self.corebank_mount),
                    error=str(corebank_health)
                )
            
            health_result = {
                "timestamp": datetime.now().isoformat(),
                "healthy": corebank_health.healthy,
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
                "error": str(e)
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
    
    async def write_data(self, filename: str, data: str, metadata: Dict = None) -> WriteResult:
        """
        Write data to CoreBank EFS with performance optimization
        """
        start_time = time.time()
        self.metrics['total_writes'] += 1
        
        try:
            # Write to CoreBank EFS with timeout
            result = await asyncio.wait_for(
                self._write_to_mount(self.corebank_mount, filename, data, metadata),
                timeout=self.write_timeout
            )
            
            end_time = time.time()
            total_duration = end_time - start_time
            
            # Update metrics
            if result.success:
                self.metrics['successful_writes'] += 1
            else:
                self.metrics['failed_writes'] += 1
            
            # Update average write time
            self.metrics['avg_write_time'] = (
                (self.metrics['avg_write_time'] * (self.metrics['total_writes'] - 1) + total_duration) /
                self.metrics['total_writes']
            )
            
            # Log performance
            logger.info(f"Write completed in {total_duration:.2f}s - "
                       f"CoreBank: {'✓' if result.success else '✗'}")
            
            # Send performance metrics
            await self._send_performance_metrics(total_duration, result.success)
            
            return result
            
        except asyncio.TimeoutError:
            error_msg = f"Write timeout after {self.write_timeout}s"
            logger.error(error_msg)
            self.metrics['failed_writes'] += 1
            
            return WriteResult(success=False, duration=self.write_timeout, error=error_msg)
        except Exception as e:
            error_msg = f"Write error: {e}"
            logger.error(error_msg)
            self.metrics['failed_writes'] += 1
            
            return WriteResult(success=False, duration=0, error=error_msg)
    
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
    
    async def read_data(self, filename: str) -> Tuple[bool, Optional[str], Optional[str]]:
        """
        Read data from CoreBank EFS
        Returns: (success, data, error)
        """
        try:
            file_path = self.corebank_mount / filename
            
            if not file_path.exists():
                return False, None, f"File not found: {filename}"
            
            async with aiofiles.open(file_path, 'r') as f:
                data = await f.read()
            
            return True, data, None
            
        except Exception as e:
            logger.error(f"Read failed from CoreBank EFS: {e}")
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
                timeout=self.write_timeout
            )
            
            successful = 0
            failed = 0
            errors = []
            
            for result in results:
                if isinstance(result, Exception):
                    failed += 1
                    errors.append(str(result))
                elif result.success:
                    successful += 1
                else:
                    failed += 1
                    errors.append("CoreBank write failed")
            
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
    
    async def list_files(self, path: str = "") -> Dict[str, any]:
        """
        List files in CoreBank EFS
        """
        try:
            start_time = time.time()
            target_path = self.corebank_mount / path if path else self.corebank_mount
            
            if not target_path.exists():
                return {
                    "success": False,
                    "error": f"Path not found: {path}",
                    "files": [],
                    "total": 0
                }
            
            files = []
            for item in target_path.iterdir():
                if not item.name.startswith('health_check_'):  # Skip health check files
                    files.append({
                        "name": item.name,
                        "type": "directory" if item.is_dir() else "file",
                        "size": item.stat().st_size if item.is_file() else 0,
                        "modified": datetime.fromtimestamp(item.stat().st_mtime).isoformat()
                    })
            
            end_time = time.time()
            duration = end_time - start_time
            
            result = {
                "success": True,
                "duration": duration,
                "path": path,
                "files": files,
                "total": len(files)
            }
            
            logger.info(f"Listed {len(files)} files in {duration:.2f}s")
            return result
            
        except Exception as e:
            logger.error(f"List files failed: {e}")
            return {
                "success": False,
                "error": str(e),
                "files": [],
                "total": 0
            }
    
    async def _send_health_metrics(self, health_data: Dict):
        """Send health metrics to CloudWatch"""
        try:
            metrics = [
                {
                    'MetricName': 'CoreBankEFSHealth',
                    'Value': 1 if health_data['corebank_efs']['healthy'] else 0,
                    'Unit': 'Count'
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
    
    async def _send_performance_metrics(self, duration: float, success: bool):
        """Send performance metrics to CloudWatch"""
        try:
            metrics = [
                {
                    'MetricName': 'WriteLatency',
                    'Value': duration * 1000,  # Convert to milliseconds
                    'Unit': 'Milliseconds'
                },
                {
                    'MetricName': 'WriteSuccessRate',
                    'Value': 100 if success else 0,
                    'Unit': 'Percent'
                },
                {
                    'MetricName': 'CoreBankWriteSuccess',
                    'Value': 1 if success else 0,
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
        logger.info("CoreBankEFSManager cleanup completed")
