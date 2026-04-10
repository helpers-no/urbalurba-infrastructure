#!/bin/bash
# service-openmetadata.sh - OpenMetadata service metadata
#
# OpenMetadata is an open-source data governance and metadata platform.

# === Service Metadata (Required) ===
SCRIPT_ID="openmetadata"
SCRIPT_NAME="OpenMetadata"
SCRIPT_DESCRIPTION="Open-source data governance and metadata platform"
SCRIPT_CATEGORY="ANALYTICS"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="340-setup-openmetadata.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n openmetadata -l app.kubernetes.io/name=openmetadata --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="340-remove-openmetadata.yml"
SCRIPT_REQUIRES="postgresql elasticsearch"
SCRIPT_PRIORITY="93"

# === Deployment Details (Optional) ===
SCRIPT_IMAGE="docker.getcollate.io/openmetadata/server:1.12.1"
SCRIPT_HELM_CHART="open-metadata/openmetadata"
SCRIPT_NAMESPACE="openmetadata"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Component"        # Component | Resource
SCRIPT_TYPE="service"          # service | tool | library | database | cache | message-broker
SCRIPT_OWNER="app-team"   # platform-team | app-team
SCRIPT_PROVIDES_APIS="openmetadata-api"
SCRIPT_CONSUMES_APIS=""

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="Open-source metadata platform for data discovery, governance, and observability"
SCRIPT_LOGO="openmetadata-logo.png"
SCRIPT_WEBSITE="https://open-metadata.org"
SCRIPT_TAGS="data-governance,metadata,data-discovery,data-lineage,data-quality,data-catalog"
SCRIPT_SUMMARY="OpenMetadata is an open-source metadata platform for data discovery, data observability, and data governance. It provides unified metadata management with 100+ connectors, column-level lineage, data quality checks, and collaboration features."
SCRIPT_DOCS="/docs/services/analytics/openmetadata"
