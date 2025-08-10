#!/usr/bin/env python3
"""
Simple EFS File Upload Application
"""

import os
import logging
from datetime import datetime
from flask import Flask, request, jsonify, render_template_string
from pathlib import Path
from werkzeug.utils import secure_filename

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = Flask(__name__)
app.config['MAX_CONTENT_LENGTH'] = 16 * 1024 * 1024  # 16MB max file size

# Configuration
EFS_MOUNT_PATH = os.environ.get('EFS_MOUNT_PATH', '/mnt/efs')
ACCOUNT_TYPE = os.environ.get('ACCOUNT_TYPE', 'unknown')

# Ensure EFS mount path exists
Path(EFS_MOUNT_PATH).mkdir(parents=True, exist_ok=True)

# Simple HTML template for file upload
UPLOAD_TEMPLATE = '''
<!DOCTYPE html>
<html>
<head>
    <title>EFS File Upload - {{account_type}}</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; }
        .container { max-width: 600px; }
        .upload-form { border: 1px solid #ccc; padding: 20px; border-radius: 5px; }
        .file-list { margin-top: 20px; }
        .file-item { padding: 5px; border-bottom: 1px solid #eee; }
        .success { color: green; }
        .error { color: red; }
        button { background: #007cba; color: white; padding: 10px 20px; border: none; border-radius: 3px; }
        button:hover { background: #005a87; }
    </style>
</head>
<body>
    <div class="container">
        <h1>EFS File Upload ({{account_type}})</h1>
        <div class="upload-form">
            <h3>Upload File</h3>
            <form action="/upload" method="post" enctype="multipart/form-data">
                <input type="file" name="file" required>
                <br><br>
                <button type="submit">Upload</button>
            </form>
        </div>
        <div class="file-list">
            <h3>Files in EFS</h3>
            <div id="files"></div>
            <button onclick="loadFiles()">Refresh Files</button>
        </div>
    </div>
    <script>
        function loadFiles() {
            fetch('/api/files')
                .then(response => response.json())
                .then(data => {
                    const filesDiv = document.getElementById('files');
                    if (data.files && data.files.length > 0) {
                        filesDiv.innerHTML = data.files.map(file => 
                            `<div class="file-item">${file.name} (${file.size} bytes)</div>`
                        ).join('');
                    } else {
                        filesDiv.innerHTML = '<div>No files found</div>';
                    }
                });
        }
        loadFiles();
    </script>
</body>
</html>
'''


def check_efs_health():
    """Simple EFS health check"""
    try:
        test_file = os.path.join(EFS_MOUNT_PATH, '.health_check.tmp')
        with open(test_file, 'w') as f:
            f.write(f"Health check at {datetime.now()}")
        os.remove(test_file)
        return True
    except Exception as e:
        logger.error(f"EFS health check failed: {e}")
        return False


@app.route('/', methods=['GET'])
def index():
    """Home page with file upload interface"""
    return render_template_string(UPLOAD_TEMPLATE, account_type=ACCOUNT_TYPE)


@app.route('/health', methods=['GET'])
def health_check():
    """Health check endpoint"""
    healthy = check_efs_health()
    return jsonify({
        'status': 'healthy' if healthy else 'unhealthy',
        'account_type': ACCOUNT_TYPE,
        'timestamp': datetime.now().isoformat(),
        'efs_mount_path': EFS_MOUNT_PATH
    }), 200 if healthy else 503


@app.route('/upload', methods=['POST'])
def upload_file():
    """Upload file to EFS"""
    try:
        if 'file' not in request.files:
            return jsonify({'error': 'No file provided'}), 400

        file = request.files['file']
        if file.filename == '':
            return jsonify({'error': 'No file selected'}), 400

        if file:
            filename = secure_filename(file.filename)
            file_path = os.path.join(EFS_MOUNT_PATH, filename)

            # Save file
            file.save(file_path)
            file_size = os.path.getsize(file_path)

            logger.info(f"File uploaded: {filename} ({file_size} bytes)")

            return jsonify({
                'success': True,
                'filename': filename,
                'size': file_size,
                'path': file_path,
                'account_type': ACCOUNT_TYPE
            })

    except Exception as e:
        logger.error(f"Upload failed: {e}")
        return jsonify({'error': str(e)}), 500


@app.route('/api/files', methods=['GET'])
def list_files():
    """List files in EFS"""
    try:
        files = []
        for item in os.listdir(EFS_MOUNT_PATH):
            file_path = os.path.join(EFS_MOUNT_PATH, item)
            if os.path.isfile(file_path) and not item.startswith('.'):
                stat = os.stat(file_path)
                files.append({
                    'name': item,
                    'size': stat.st_size,
                    'modified': datetime.fromtimestamp(stat.st_mtime).isoformat()
                })

        return jsonify({
            'files': files,
            'total': len(files),
            'account_type': ACCOUNT_TYPE
        })

    except Exception as e:
        logger.error(f"List files failed: {e}")
        return jsonify({'error': str(e)}), 500


@app.route('/api/download/<filename>', methods=['GET'])
def download_file(filename):
    """Download file from EFS"""
    try:
        filename = secure_filename(filename)
        file_path = os.path.join(EFS_MOUNT_PATH, filename)

        if not os.path.exists(file_path):
            return jsonify({'error': 'File not found'}), 404

        from flask import send_file
        return send_file(file_path, as_attachment=True)

    except Exception as e:
        logger.error(f"Download failed: {e}")
        return jsonify({'error': str(e)}), 500


if __name__ == '__main__':
    logger.info(f"Starting Simple EFS Upload App for {ACCOUNT_TYPE} account")
    logger.info(f"EFS Mount Path: {EFS_MOUNT_PATH}")

    # Verify EFS mount
    if check_efs_health():
        logger.info("EFS mount is healthy")
    else:
        logger.warning("EFS mount issue detected")

    app.run(host='0.0.0.0', port=5000, debug=False)
