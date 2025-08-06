# Simple EFS File Upload Application

A minimalist Flask application for uploading files to Amazon EFS across AWS accounts.

## Features

- **Web-based file upload interface** - Simple HTML form for uploading files
- **File listing** - View all files stored in EFS
- **File download** - Download files from EFS
- **Health check** - Verify EFS mount connectivity
- **Cross-account support** - Works with EFS mounted from different AWS accounts

## API Endpoints

- `GET /` - Web interface for file upload
- `POST /upload` - Upload a file to EFS
- `GET /api/files` - List all files in EFS (JSON)
- `GET /api/download/<filename>` - Download a specific file
- `GET /health` - Health check endpoint

## Environment Variables

- `EFS_MOUNT_PATH` - Path where EFS is mounted (default: `/mnt/efs`)
- `ACCOUNT_TYPE` - Account identifier (e.g., "corebank", "satellite")

## Usage

1. Access the web interface at `http://localhost:5000`
2. Use the upload form to select and upload files
3. View uploaded files in the file list
4. Click "Refresh Files" to update the file list

## File Storage

All files are stored directly in the EFS mount point (`/mnt/efs`) without any metadata wrapping, making them easily accessible from other applications or accounts.

## Docker

The application runs in a Docker container with:
- Python 3.11 slim base image
- NFS utilities for EFS mounting
- Health check endpoint
- File size limit: 16MB per upload
