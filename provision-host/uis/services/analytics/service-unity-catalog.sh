#!/bin/bash
# service-unity-catalog.sh - Unity Catalog service metadata
#
# Unity Catalog is an open-source data catalog for data governance.

# === Service Metadata (Required) ===
SCRIPT_ID="unity-catalog"
SCRIPT_NAME="Unity Catalog"
SCRIPT_DESCRIPTION="Open-source data catalog and governance"
SCRIPT_CATEGORY="ANALYTICS"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="320-setup-unity-catalog.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n unity-catalog -l app=unity-catalog,component=server --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="320-remove-unity-catalog.yml"
SCRIPT_REQUIRES="postgresql"
SCRIPT_PRIORITY="90"

# === Deployment Details (Optional) ===
SCRIPT_IMAGE="unitycatalog/unitycatalog:latest"
SCRIPT_NAMESPACE="unity-catalog"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Component"        # Component | Resource
SCRIPT_TYPE="service"          # service | tool | library | database | cache | message-broker
SCRIPT_OWNER="app-team"   # platform-team | app-team

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="Open-source data catalog for unified governance across data and AI assets"
SCRIPT_LOGO="unity-catalog-logo.png"
SCRIPT_WEBSITE="https://www.unitycatalog.io"
SCRIPT_TAGS="data-catalog,governance,metadata,lakehouse,data-lineage"
SCRIPT_SUMMARY="Unity Catalog is an open-source data catalog that provides unified governance for data and AI assets. It enables fine-grained access control, data lineage tracking, and metadata management across your data lakehouse."
SCRIPT_DOCS="/docs/services/analytics/unity-catalog"
