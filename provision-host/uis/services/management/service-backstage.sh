#!/bin/bash
# service-backstage.sh - Backstage (RHDH) service metadata
#
# Red Hat Developer Hub — an open-source Backstage distribution
# providing a software catalog, Kubernetes visibility, and Grafana integration.

# === Service Metadata (Required) ===
SCRIPT_ID="backstage"
SCRIPT_NAME="Backstage (RHDH)"
SCRIPT_DESCRIPTION="Developer portal with software catalog and Kubernetes visibility"
SCRIPT_CATEGORY="MANAGEMENT"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="650-setup-backstage.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n backstage -l app.kubernetes.io/instance=backstage --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="650-remove-backstage.yml"
SCRIPT_REQUIRES="postgresql"
SCRIPT_PRIORITY="80"

# === Deployment Details (Optional) ===
SCRIPT_HELM_CHART="rhdh-chart/backstage"
SCRIPT_NAMESPACE="backstage"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Component"
SCRIPT_TYPE="tool"
SCRIPT_OWNER="platform-team"

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="Developer portal for software catalog and service visibility"
SCRIPT_LOGO="backstage-logo.svg"
SCRIPT_WEBSITE="https://backstage.io"
SCRIPT_TAGS="developer-portal,catalog,backstage,rhdh,kubernetes"
SCRIPT_SUMMARY="Backstage (via Red Hat Developer Hub) provides a centralized developer portal with a software catalog showing all UIS services, their relationships, Kubernetes pod status, and Grafana dashboard links."
SCRIPT_DOCS="/docs/services/management/backstage"
