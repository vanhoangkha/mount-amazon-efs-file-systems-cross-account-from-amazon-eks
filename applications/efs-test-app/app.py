#!/usr/bin/env python3
"""
Simple EFS Test Application
Tests dual-write functionality to both local and cross-account EFS
"""

import os
import time
import json
import logging
from datetime import datetime
from pathlib import Path
from flask import Flask, request, jsonify
import asyncio
import aiofiles
from concurrent.futures import ThreadPoolExecutor

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

app = Flask(__name__)

# Configuration
LOCAL_EFS_PATH = os.getenv('LOCAL_EFS_PATH', '/mnt/efs-local')
COREBANK_EFS_PATH = os.getenv('COREBANK_EFS_PATH', '/mnt/efs-corebank')
APP_NAME = os.getenv('APP_NAME', 'efs-test-app')
DUAL_WRITE_ENABLED = os.getenv('DUAL_WRITE_ENABLED', 'true').lower() == 'true'

# Ensure directories exist
Path(LOCAL_EFS_PATH).mkdir(parents=True, exist_ok=True)
Path(COREBANK_EFS_PATH).mkdir(parents=True, exist_ok=True)

# Thread pool for async operations
executor = ThreadPoolExecutor(max_workers=10)

class EFSTestManager:
    def __init__(self):
        self.local_path = Path(LOCAL_EFS_PATH)
        self.corebank_path = Path(COREBANK_EFS_PATH)
        self.stats = {
            'total_writes': 0,
            'successful_writes': 0,
            'failed_writes': 0,
            'total_reads': 0,
            'successful_reads': 0,
            'failed_reads': 0,
            'start_time': time.time()
        }
    
    def write_file(self, filename, content, metadata=None):
        """Write file to both EFS mounts"""
        results = {
            'local': {'success': False, 'duration': 0, 'error': None},
            'corebank': {'success': False, 'duration': 0, 'error': None}
        }
        
        # Prepare data
        data = {
            'timestamp': datetime.now().isoformat(),
            'app_name': APP_NAME,
            'content': content,
            'metadata': metadata or {}
        }
        json_data = json.dumps(data, indent=2)
        
        # Write to local EFS
        try:
            start_time = time.time()
            local_file = self.local_path / filename
            local_file.parent.mkdir(parents=True, exist_ok=True)
            
            with open(local_file, 'w') as f:
                f.write(json_data)
                f.flush()
                os.fsync(f.fileno())
            
            results['local']['success'] = True
            results['local']['duration'] = time.time() - start_time
            logger.info(f"Successfully wrote to local EFS: {filename}")
            
        except Exception as e:
            results['local']['error'] = str(e)
            logger.error(f"Failed to write to local EFS: {e}")
        
        # Write to CoreBank EFS (if enabled)
        if DUAL_WRITE_ENABLED:
            try:
                start_time = time.time()
                corebank_file = self.corebank_path / filename
                corebank_file.parent.mkdir(parents=True, exist_ok=True)
                
                with open(corebank_file, 'w') as f:
                    f.write(json_data)
                    f.flush()
                    os.fsync(f.fileno())
                
                results['corebank']['success'] = True
                results['corebank']['duration'] = time.time() - start_time
                logger.info(f"Successfully wrote to CoreBank EFS: {filename}")
                
            except Exception as e:
                results['corebank']['error'] = str(e)
                logger.error(f"Failed to write to CoreBank EFS: {e}")
        else:
            results['corebank']['error'] = "Dual write disabled"
        
        # Update stats
        self.stats['total_writes'] += 1
        if results['local']['success'] or results['corebank']['success']:
            self.stats['successful_writes'] += 1
        else:
            self.stats['failed_writes'] += 1
        
        return results
    
    def read_file(self, filename, from_mount='local'):
        """Read file from specified EFS mount"""
        self.stats['total_reads'] += 1
        
        try:
            if from_mount == 'local':
                file_path = self.local_path / filename
            elif from_mount == 'corebank':
                file_path = self.corebank_path / filename
            else:
                raise ValueError(f"Invalid mount: {from_mount}")
            
            if not file_path.exists():
                raise FileNotFoundError(f"File not found: {filename}")
            
            start_time = time.time()
            with open(file_path, 'r') as f:
                content = f.read()
            
            duration = time.time() - start_time
            self.stats['successful_reads'] += 1
            
            logger.info(f"Successfully read from {from_mount} EFS: {filename}")
            
            return {
                'success': True,
                'content': json.loads(content),
                'duration': duration,
                'from_mount': from_mount
            }
            
        except Exception as e:
            self.stats['failed_reads'] += 1
            logger.error(f"Failed to read from {from_mount} EFS: {e}")
            
            return {
                'success': False,
                'error': str(e),
                'from_mount': from_mount
            }
    
    def list_files(self, mount='local', path=''):
        """List files in EFS mount"""
        try:
            if mount == 'local':
                base_path = self.local_path
            elif mount == 'corebank':
                base_path = self.corebank_path
            else:
                raise ValueError(f"Invalid mount: {mount}")
            
            target_path = base_path / path if path else base_path
            
            if not target_path.exists():
                return {'success': False, 'error': f"Path not found: {path}"}
            
            files = []
            for item in target_path.iterdir():
                files.append({
                    'name': item.name,
                    'type': 'directory' if item.is_dir() else 'file',
                    'size': item.stat().st_size if item.is_file() else 0,
                    'modified': datetime.fromtimestamp(item.stat().st_mtime).isoformat()
                })
            
            return {
                'success': True,
                'mount': mount,
                'path': path,
                'files': files,
                'total': len(files)
            }
            
        except Exception as e:
            logger.error(f"Failed to list files from {mount}: {e}")
            return {'success': False, 'error': str(e)}
    
    def health_check(self):
        """Check health of both EFS mounts"""
        health = {
            'timestamp': datetime.now().isoformat(),
            'app_name': APP_NAME,
            'dual_write_enabled': DUAL_WRITE_ENABLED,
            'local_efs': self._check_mount_health(self.local_path, 'local'),
            'corebank_efs': self._check_mount_health(self.corebank_path, 'corebank'),
            'stats': self.stats.copy()
        }
        
        # Calculate uptime
        health['stats']['uptime_seconds'] = time.time() - self.stats['start_time']
        
        # Overall health
        health['healthy'] = (
            health['local_efs']['healthy'] and 
            (health['corebank_efs']['healthy'] or not DUAL_WRITE_ENABLED)
        )
        
        return health
    
    def _check_mount_health(self, mount_path, mount_name):
        """Check health of a specific mount"""
        try:
            # Test write
            test_file = mount_path / f"health_check_{int(time.time())}.tmp"
            test_data = f"health_check_{mount_name}_{time.time()}"
            
            start_time = time.time()
            with open(test_file, 'w') as f:
                f.write(test_data)
                f.flush()
                os.fsync(f.fileno())
            
            # Test read
            with open(test_file, 'r') as f:
                read_data = f.read()
            
            # Verify data
            if read_data != test_data:
                raise Exception("Data integrity check failed")
            
            # Cleanup
            test_file.unlink()
            
            duration = (time.time() - start_time) * 1000  # ms
            
            return {
                'healthy': True,
                'latency_ms': round(duration, 2),
                'writable': True,
                'readable': True,
                'mount_path': str(mount_path)
            }
            
        except Exception as e:
            return {
                'healthy': False,
                'error': str(e),
                'writable': False,
                'readable': False,
                'mount_path': str(mount_path)
            }

# Initialize EFS manager
efs_manager = EFSTestManager()

# Flask routes
@app.route('/')
def home():
    """Home endpoint"""
    return jsonify({
        'service': 'EFS Test Application',
        'version': '1.0.0',
        'app_name': APP_NAME,
        'dual_write_enabled': DUAL_WRITE_ENABLED,
        'mount_points': {
            'local': LOCAL_EFS_PATH,
            'corebank': COREBANK_EFS_PATH
        },
        'endpoints': {
            'health': '/health',
            'write': '/write',
            'read': '/read',
            'list': '/list',
            'stats': '/stats',
            'test': '/test'
        }
    })

@app.route('/health')
def health():
    """Health check endpoint"""
    return jsonify(efs_manager.health_check())

@app.route('/write', methods=['POST'])
def write_file():
    """Write file to EFS"""
    try:
        data = request.get_json()
        filename = data.get('filename')
        content = data.get('content')
        metadata = data.get('metadata', {})
        
        if not filename or not content:
            return jsonify({'error': 'filename and content are required'}), 400
        
        results = efs_manager.write_file(filename, content, metadata)
        
        return jsonify({
            'success': True,
            'results': results,
            'timestamp': datetime.now().isoformat()
        })
        
    except Exception as e:
        logger.error(f"Write endpoint error: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/read')
def read_file():
    """Read file from EFS"""
    try:
        filename = request.args.get('filename')
        from_mount = request.args.get('from', 'local')
        
        if not filename:
            return jsonify({'error': 'filename parameter is required'}), 400
        
        result = efs_manager.read_file(filename, from_mount)
        
        if result['success']:
            return jsonify(result)
        else:
            return jsonify(result), 404
            
    except Exception as e:
        logger.error(f"Read endpoint error: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/list')
def list_files():
    """List files in EFS"""
    try:
        mount = request.args.get('mount', 'local')
        path = request.args.get('path', '')
        
        result = efs_manager.list_files(mount, path)
        
        if result['success']:
            return jsonify(result)
        else:
            return jsonify(result), 404
            
    except Exception as e:
        logger.error(f"List endpoint error: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/stats')
def get_stats():
    """Get application statistics"""
    stats = efs_manager.stats.copy()
    stats['uptime_seconds'] = time.time() - stats['start_time']
    stats['timestamp'] = datetime.now().isoformat()
    
    return jsonify(stats)

@app.route('/test', methods=['POST'])
def run_test():
    """Run EFS test suite"""
    try:
        test_results = []
        
        # Test 1: Write test files
        for i in range(5):
            filename = f"test/test_file_{i}_{int(time.time())}.json"
            content = f"Test content {i} - {datetime.now()}"
            metadata = {'test_id': i, 'test_type': 'automated'}
            
            result = efs_manager.write_file(filename, content, metadata)
            test_results.append({
                'test': f'write_test_{i}',
                'filename': filename,
                'result': result
            })
        
        # Test 2: Read test files
        for i, test_result in enumerate(test_results):
            if test_result['result']['local']['success']:
                filename = test_result['filename']
                read_result = efs_manager.read_file(filename, 'local')
                test_results[i]['read_result'] = read_result
        
        # Test 3: List files
        list_result = efs_manager.list_files('local', 'test')
        
        return jsonify({
            'success': True,
            'test_results': test_results,
            'list_result': list_result,
            'timestamp': datetime.now().isoformat()
        })
        
    except Exception as e:
        logger.error(f"Test endpoint error: {e}")
        return jsonify({'error': str(e)}), 500

if __name__ == '__main__':
    logger.info(f"Starting EFS Test Application: {APP_NAME}")
    logger.info(f"Local EFS Path: {LOCAL_EFS_PATH}")
    logger.info(f"CoreBank EFS Path: {COREBANK_EFS_PATH}")
    logger.info(f"Dual Write Enabled: {DUAL_WRITE_ENABLED}")
    
    app.run(host='0.0.0.0', port=8080, debug=False)
