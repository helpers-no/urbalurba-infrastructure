#!/bin/bash
# service-pgadmin.sh - pgAdmin service metadata
#
# pgAdmin is a web-based administration tool for PostgreSQL databases.

# === Service Metadata (Required) ===
SCRIPT_ID="pgadmin"
SCRIPT_NAME="pgAdmin"
SCRIPT_DESCRIPTION="Web-based PostgreSQL database administration"
SCRIPT_CATEGORY="MANAGEMENT"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="641-adm-pgadmin.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n default -l app.kubernetes.io/name=pgadmin4 --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="641-remove-pgadmin.yml"
SCRIPT_REQUIRES="postgresql"
SCRIPT_PRIORITY="90"

# === Deployment Details (Optional) ===
SCRIPT_HELM_CHART="runix/pgadmin4"
SCRIPT_NAMESPACE="default"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Component"        # Component | Resource
SCRIPT_TYPE="tool"          # service | tool | library | database | cache | message-broker
SCRIPT_OWNER="platform-team"   # platform-team | app-team

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="Web administration interface for PostgreSQL"
SCRIPT_LOGO="pgadmin-logo.png"
SCRIPT_WEBSITE="https://www.pgadmin.org"
SCRIPT_TAGS="postgresql,database,admin,management,web-ui"
SCRIPT_SUMMARY="pgAdmin is a feature-rich open source administration and development platform for PostgreSQL. It provides a graphical interface for managing databases, running queries, and monitoring server activity."
SCRIPT_DOCS="/docs/services/management/pgadmin"
