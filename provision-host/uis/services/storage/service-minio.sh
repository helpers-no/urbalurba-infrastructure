#!/bin/bash
# service-minio.sh - MinIO service metadata
#
# MinIO is an S3-compatible object storage server. It gives applications a
# bucket/object API (images, uploads, backups, data-lake files) without a
# cloud dependency, and a web console for browsing buckets.

# === Service Metadata (Required) ===
SCRIPT_ID="minio"
SCRIPT_NAME="MinIO"
SCRIPT_DESCRIPTION="S3-compatible object storage"
SCRIPT_CATEGORY="STORAGE"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="045-setup-minio.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n default -l app=minio --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="045-remove-minio.yml"
SCRIPT_REQUIRES=""
SCRIPT_PRIORITY="34"

# === Deployment Details (Optional) ===
SCRIPT_HELM_CHART="minio/minio"
SCRIPT_NAMESPACE="default"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Resource"          # Component | Resource
SCRIPT_TYPE="object-storage"    # service | tool | library | database | cache | message-broker
SCRIPT_OWNER="platform-team"    # platform-team | app-team

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="S3-compatible object storage for files, images, and backups"
SCRIPT_LOGO="minio-logo.svg"
SCRIPT_WEBSITE="https://min.io"
SCRIPT_TAGS="object-storage,s3,buckets,files,images,blob-storage"
SCRIPT_SUMMARY="MinIO is a high-performance, S3-compatible object storage server. Applications talk to it with any AWS S3 SDK, so code written against MinIO in UIS runs unchanged against AWS S3, Azure Blob (via S3 gateway), or a production MinIO cluster. Deployed in standalone mode with a persistent volume, an S3 API on port 9000, and a web console on port 9001."
SCRIPT_DOCS="/docs/services/storage/minio"

# === Template Integration (Optional) ===
# The S3 API port is what applications need on the host machine
# (./uis expose minio -> localhost:39900). The console is reached
# through Traefik at http://minio.localhost instead.
SCRIPT_EXPOSE_PORT="39900"
