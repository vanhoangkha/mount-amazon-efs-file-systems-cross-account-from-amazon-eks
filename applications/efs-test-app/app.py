#!/usr/bin/env python3
"""
Simple EFS Test Application
Tests CoreBank EFS functionality across accounts
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
COREBANK_EFS_PATH = os.getenv('COREBANK_EFS_PATH', '/mnt/efs-corebank')
APP_NAME = os.getenv('APP_NAME', 'efs-test-app')

# Ensure directories exist
Path(COREBANK_EFS_PATH).mkdir(parents=True, exist_ok=True)

# Thread pool for async operations
executor = ThreadPoolExecutor(max_workers=10)

class EFSTestManager:
    def __init__(self):
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
        """Write file to CoreBank EFS"""
        result = {'success': False, 'duration': 0, 'error': None}
        
        # Prepare data
        data = {
            'timestamp': datetime.now().isoformat(),
            'app_name': APP_NAME,
            'content': content,
            'metadata': metadata or {}
        }
        json_data = json.dumps(data, indent=2)
        
        # Write to CoreBank EFS
        try:
            start_time = time.time()
            corebank_file = self.corebank_path / filename
            corebank_file.parent.mkdir(parents=True, exist_ok=True)
            
            with open(corebank_file, 'w') as f:
                f.write(json_data)
                f.flush()
                os.fsync(f.fileno())
            
            result['success'] = True
            result['duration'] = time.time() - start_time
            logger.info(f"Successfully wrote to CoreBank EFS: {filename}")
            
        except Exception as e:
            result['error'] = str(e)
            logger.error(f"Failed to write to CoreBank EFS: {e}")
        
        # Update stats
        self.stats['total_writes'] += 1
        if result['success']:
            self.stats['successful_writes'] += 1
        else:
            self.stats['failed_writes'] += 1
        
        return result
    
    def read_file(self, filename):
        """Read file from CoreBank EFS"""
        self.stats['total_reads'] += 1
        
        try:
            file_path = self.corebank_path / filename
            
            if not file_path.exists():
                raise FileNotFoundError(f"File not found: {filename}")
            
            start_time = time.time()
            with open(file_path, 'r') as f:
                content = f.read()
            
            duration = time.time() - start_time
            self.stats['successful_reads'] += 1
            
            logger.info(f"Successfully read from CoreBank EFS: {filename}")
            
            return {
                'success': True,
                'content': json.loads(content),
                'duration': duration
            }
            
        except Exception as e:
            self.stats['failed_reads'] += 1
            logger.error(f"Failed to read from CoreBank EFS: {e}")
            
            return {
                'success': False,
                'error': str(e)
            }
    
    def list_files(self, path=''):
        """List files in CoreBank EFS"""
        try:
            target_path = self.corebank_path / path if path else self.corebank_path
            
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
                'path': path,
                'files': files,
                'total': len(files)
            }
            
        except Exception as e:
            logger.error(f"Failed to list files from CoreBank EFS: {e}")
            return {'success': False, 'error': str(e)}
    
    def health_check(self):
        """Check health of CoreBank EFS mount"""
        health = {
            'timestamp': datetime.now().isoformat(),
            'app_name': APP_NAME,
            'corebank_efs': self._check_mount_health(self.corebank_path, 'corebank'),
            'stats': self.stats.copy()
        }
        
        # Calculate uptime
        health['stats']['uptime_seconds'] = time.time() - self.stats['start_time']
        
        # Overall health
        health['healthy'] = health['corebank_efs']['healthy']
        
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
        'mount_points': {
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
        
        result = efs_manager.write_file(filename, content, metadata)
        
        return jsonify({
            'success': True,
            'result': result,
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
        
        if not filename:
            return jsonify({'error': 'filename parameter is required'}), 400
        
        result = efs_manager.read_file(filename)
        
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
        path = request.args.get('path', '')
        
        result = efs_manager.list_files(path)
        
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
            if test_result['result']['success']:
                filename = test_result['filename']
                read_result = efs_manager.read_file(filename)
                test_results[i]['read_result'] = read_result
        
        # Test 3: List files
        list_result = efs_manager.list_files('test')
        
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
    logger.info(f"CoreBank EFS Path: {COREBANK_EFS_PATH}")
    
    app.run(host='0.0.0.0', port=8080, debug=False)