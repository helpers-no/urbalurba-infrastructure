#!/bin/bash
# service-postgresql.sh - PostgreSQL service metadata
#
# PostgreSQL is a powerful open-source relational database.

# === Service Metadata (Required) ===
SCRIPT_ID="postgresql"
SCRIPT_NAME="PostgreSQL"
SCRIPT_DESCRIPTION="Open-source relational database"
SCRIPT_CATEGORY="DATABASES"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="040-database-postgresql.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n default -l app.kubernetes.io/name=postgresql --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="040-remove-database-postgresql.yml"
SCRIPT_REQUIRES=""
SCRIPT_PRIORITY="30"

# === Deployment Details (Optional) ===
SCRIPT_HELM_CHART="bitnami/postgresql"
SCRIPT_NAMESPACE="default"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Resource"        # Component | Resource
SCRIPT_TYPE="database"          # service | tool | library | database | cache | message-broker
SCRIPT_OWNER="platform-team"   # platform-team | app-team

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="World's most advanced open-source relational database"
SCRIPT_LOGO="postgresql-logo.svg"
SCRIPT_WEBSITE="https://www.postgresql.org"
SCRIPT_TAGS="database,sql,relational,postgres,rdbms"
SCRIPT_SUMMARY="PostgreSQL is a powerful, open-source object-relational database system with over 35 years of active development. It has earned a strong reputation for reliability, feature robustness, and performance."
SCRIPT_DOCS="/docs/services/databases/postgresql"

# === Template Integration (Optional) ===
SCRIPT_CONFIGURABLE="true"
SCRIPT_EXPOSE_PORT="35432"
