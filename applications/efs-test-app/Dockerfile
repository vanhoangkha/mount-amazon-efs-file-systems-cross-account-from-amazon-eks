FROM python:3.11-slim

# Install system dependencies
RUN apt-get update && apt-get install -y \
    nfs-common \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy requirements and install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY app.py .

# Create non-root user
RUN groupadd -r appuser && useradd -r -g appuser appuser

# Create mount point directories
RUN mkdir -p /mnt/efs-local /mnt/efs-corebank && \
    chown -R appuser:appuser /mnt/efs-local /mnt/efs-corebank /app

# Switch to non-root user
USER appuser

# Set environment variables
ENV LOCAL_EFS_PATH=/mnt/efs-local
ENV COREBANK_EFS_PATH=/mnt/efs-corebank
ENV DUAL_WRITE_ENABLED=true
ENV APP_NAME=efs-test-app

# Expose port
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

# Run application with gunicorn
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "4", "--timeout", "120", "app:app"]
