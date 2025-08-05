#!/usr/bin/env python3
"""
EFS Cross-Account Test Application
A simple Flask application for testing EFS cross-account functionality
"""

import os
import json
import time
import uuid
import logging
from datetime import datetime
from flask import Flask, request, jsonify, abort
from pathlib import Path
import boto3
import psutil

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

app = Flask(__name__)

# Configuration
EFS_MOUNT_PATH = os.environ.get('EFS_MOUNT_PATH', '/mnt/efs')
ACCOUNT_TYPE = os.environ.get('ACCOUNT_TYPE', 'unknown')
AWS_REGION = os.environ.get('AWS_REGION', 'ap-southeast-1')
WRITE_TIMEOUT = int(os.environ.get('WRITE_TIMEOUT', '30'))

# Ensure EFS mount path exists
Path(EFS_MOUNT_PATH).mkdir(parents=True, exist_ok=True)

# Application statistics
app_stats = {
    'start_time': datetime.utcnow().isoformat(),
    'write_operations': 0,
    'read_operations': 0,
    'write_errors': 0,
    'read_errors': 0,
    'total_bytes_written': 0,
    'total_bytes_read': 0
}


def get_system_info():
    """Get system information"""
    try:
        return {
            'cpu_percent': psutil.cpu_percent(),
            'memory_percent': psutil.virtual_memory().percent,
            'disk_usage': psutil.disk_usage('/').percent,
            'efs_mount_available': os.path.ismount(EFS_MOUNT_PATH) or os.path.exists(EFS_MOUNT_PATH)
        }
    except Exception as e:
        logger.error(f"Error getting system info: {e}")
        return {}


def check_efs_health():
    """Check EFS mount health"""
    try:
        # Test write operation
        test_file = os.path.join(
            EFS_MOUNT_PATH, f'.health_check_{int(time.time())}.tmp')
        test_content = f"Health check from {ACCOUNT_TYPE} at {datetime.utcnow().isoformat()}"

        start_time = time.time()
        with open(test_file, 'w') as f:
            f.write(test_content)

        # Test read operation
        with open(test_file, 'r') as f:
            read_content = f.read()

        # Cleanup
        os.remove(test_file)

        elapsed_time = time.time() - start_time

        return {
            'healthy': True,
            'latency_ms': round(elapsed_time * 1000, 2),
            'test_content_match': test_content == read_content
        }
    except Exception as e:
        logger.error(f"EFS health check failed: {e}")
        return {
            'healthy': False,
            'error': str(e)
        }


@app.route('/health', methods=['GET'])
def health_check():
    """Health check endpoint"""
    efs_health = check_efs_health()
    system_info = get_system_info()

    status = {
        'status': 'healthy' if efs_health.get('healthy', False) else 'unhealthy',
        'account_type': ACCOUNT_TYPE,
        'timestamp': datetime.utcnow().isoformat(),
        'efs_mount_path': EFS_MOUNT_PATH,
        'efs_health': efs_health,
        'system_info': system_info,
        'uptime_seconds': (datetime.utcnow() - datetime.fromisoformat(app_stats['start_time'])).total_seconds()
    }

    http_status = 200 if efs_health.get('healthy', False) else 503
    return jsonify(status), http_status


@app.route('/stats', methods=['GET'])
def get_stats():
    """Get application statistics"""
    return jsonify({
        'app_stats': app_stats,
        'account_type': ACCOUNT_TYPE,
        'efs_mount_path': EFS_MOUNT_PATH,
        'system_info': get_system_info()
    })


@app.route('/write', methods=['POST'])
def write_file():
    """Write file to EFS"""
    try:
        start_time = time.time()

        # Get request data
        data = request.get_json()
        if not data:
            abort(400, description="JSON data required")

        filename = data.get('filename')
        content = data.get('content', '')
        metadata = data.get('metadata', {})

        if not filename:
            abort(400, description="Filename is required")

        # Prepare file path
        file_path = os.path.join(EFS_MOUNT_PATH, filename)
        os.makedirs(os.path.dirname(file_path), exist_ok=True)

        # Prepare file content with metadata
        file_data = {
            'content': content,
            'metadata': {
                **metadata,
                'written_by': ACCOUNT_TYPE,
                'written_at': datetime.utcnow().isoformat(),
                'file_id': str(uuid.uuid4())
            }
        }

        # Write file
        with open(file_path, 'w') as f:
            json.dump(file_data, f, indent=2)

        # Update statistics
        elapsed_time = time.time() - start_time
        bytes_written = len(json.dumps(file_data).encode('utf-8'))

        app_stats['write_operations'] += 1
        app_stats['total_bytes_written'] += bytes_written

        logger.info(
            f"File written: {filename} ({bytes_written} bytes) in {elapsed_time:.3f}s")

        return jsonify({
            'success': True,
            'filename': filename,
            'bytes_written': bytes_written,
            'write_time_ms': round(elapsed_time * 1000, 2),
            'file_path': file_path,
            'account_type': ACCOUNT_TYPE
        })

    except Exception as e:
        app_stats['write_errors'] += 1
        logger.error(f"Write operation failed: {e}")
        return jsonify({
            'success': False,
            'error': str(e),
            'account_type': ACCOUNT_TYPE
        }), 500


@app.route('/read', methods=['GET'])
def read_file():
    """Read file from EFS"""
    try:
        start_time = time.time()

        filename = request.args.get('filename')
        if not filename:
            abort(400, description="Filename parameter is required")

        file_path = os.path.join(EFS_MOUNT_PATH, filename)

        if not os.path.exists(file_path):
            abort(404, description=f"File not found: {filename}")

        # Read file
        with open(file_path, 'r') as f:
            file_data = json.load(f)

        # Update statistics
        elapsed_time = time.time() - start_time
        bytes_read = os.path.getsize(file_path)

        app_stats['read_operations'] += 1
        app_stats['total_bytes_read'] += bytes_read

        logger.info(
            f"File read: {filename} ({bytes_read} bytes) in {elapsed_time:.3f}s")

        return jsonify({
            'success': True,
            'filename': filename,
            'data': file_data,
            'bytes_read': bytes_read,
            'read_time_ms': round(elapsed_time * 1000, 2),
            'read_by': ACCOUNT_TYPE
        })

    except Exception as e:
        app_stats['read_errors'] += 1
        logger.error(f"Read operation failed: {e}")
        return jsonify({
            'success': False,
            'error': str(e),
            'account_type': ACCOUNT_TYPE
        }), 500


@app.route('/list', methods=['GET'])
def list_files():
    """List files in EFS"""
    try:
        start_time = time.time()

        # Get directory listing
        files = []
        for root, dirs, filenames in os.walk(EFS_MOUNT_PATH):
            for filename in filenames:
                if filename.startswith('.health_check'):
                    continue  # Skip health check temp files

                file_path = os.path.join(root, filename)
                relative_path = os.path.relpath(file_path, EFS_MOUNT_PATH)

                try:
                    stat = os.stat(file_path)
                    files.append({
                        'filename': relative_path,
                        'size_bytes': stat.st_size,
                        'modified_time': datetime.fromtimestamp(stat.st_mtime).isoformat(),
                        'full_path': file_path
                    })
                except Exception as e:
                    logger.warning(
                        f"Error getting file stats for {file_path}: {e}")

        elapsed_time = time.time() - start_time

        return jsonify({
            'success': True,
            'files': files,
            'total_files': len(files),
            'list_time_ms': round(elapsed_time * 1000, 2),
            'account_type': ACCOUNT_TYPE,
            'mount_path': EFS_MOUNT_PATH
        })

    except Exception as e:
        logger.error(f"List operation failed: {e}")
        return jsonify({
            'success': False,
            'error': str(e),
            'account_type': ACCOUNT_TYPE
        }), 500


@app.route('/test', methods=['POST'])
def run_test():
    """Run automated test suite"""
    test_results = []
    overall_success = True

    try:
        # Test 1: Health check
        health_result = check_efs_health()
        test_results.append({
            'test': 'health_check',
            'success': health_result.get('healthy', False),
            'details': health_result
        })
        if not health_result.get('healthy', False):
            overall_success = False

        # Test 2: Write operation
        test_filename = f"test/auto_test_{int(time.time())}.json"
        test_content = {
            'test_data': 'automated test',
            'timestamp': datetime.utcnow().isoformat(),
            'account': ACCOUNT_TYPE
        }

        try:
            file_path = os.path.join(EFS_MOUNT_PATH, test_filename)
            os.makedirs(os.path.dirname(file_path), exist_ok=True)

            start_time = time.time()
            with open(file_path, 'w') as f:
                json.dump(test_content, f)
            write_time = time.time() - start_time

            test_results.append({
                'test': 'write_operation',
                'success': True,
                'details': {
                    'filename': test_filename,
                    'write_time_ms': round(write_time * 1000, 2)
                }
            })
        except Exception as e:
            test_results.append({
                'test': 'write_operation',
                'success': False,
                'error': str(e)
            })
            overall_success = False

        # Test 3: Read operation
        try:
            start_time = time.time()
            with open(file_path, 'r') as f:
                read_content = json.load(f)
            read_time = time.time() - start_time

            content_match = read_content == test_content
            test_results.append({
                'test': 'read_operation',
                'success': content_match,
                'details': {
                    'filename': test_filename,
                    'read_time_ms': round(read_time * 1000, 2),
                    'content_match': content_match
                }
            })
            if not content_match:
                overall_success = False

        except Exception as e:
            test_results.append({
                'test': 'read_operation',
                'success': False,
                'error': str(e)
            })
            overall_success = False

        # Cleanup test file
        try:
            os.remove(file_path)
        except Exception as e:
            logger.warning(f"Failed to cleanup test file: {e}")

        return jsonify({
            'overall_success': overall_success,
            'account_type': ACCOUNT_TYPE,
            'test_results': test_results,
            'timestamp': datetime.utcnow().isoformat()
        })

    except Exception as e:
        logger.error(f"Test suite failed: {e}")
        return jsonify({
            'overall_success': False,
            'error': str(e),
            'account_type': ACCOUNT_TYPE,
            'test_results': test_results
        }), 500


@app.route('/', methods=['GET'])
def index():
    """Index endpoint with API documentation"""
    return jsonify({
        'service': 'EFS Cross-Account Test Application',
        'account_type': ACCOUNT_TYPE,
        'version': '1.0.0',
        'endpoints': {
            'GET /health': 'Health check with EFS connectivity test',
            'GET /stats': 'Application statistics and metrics',
            'POST /write': 'Write file to EFS (JSON: {filename, content, metadata})',
            'GET /read': 'Read file from EFS (param: filename)',
            'GET /list': 'List all files in EFS',
            'POST /test': 'Run automated test suite'
        },
        'efs_mount_path': EFS_MOUNT_PATH,
        'uptime_seconds': (datetime.utcnow() - datetime.fromisoformat(app_stats['start_time'])).total_seconds()
    })


if __name__ == '__main__':
    logger.info(f"Starting EFS Test App for {ACCOUNT_TYPE} account")
    logger.info(f"EFS Mount Path: {EFS_MOUNT_PATH}")

    # Verify EFS mount
    health = check_efs_health()
    if health.get('healthy'):
        logger.info("EFS mount is healthy")
    else:
        logger.warning(f"EFS mount issue: {health.get('error', 'Unknown')}")

    app.run(host='0.0.0.0', port=5000, debug=False)
