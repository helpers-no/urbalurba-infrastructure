#!/bin/bash
# service-mysql.sh - MySQL service metadata
#
# MySQL is an open-source relational database management system.

# === Service Metadata (Required) ===
SCRIPT_ID="mysql"
SCRIPT_NAME="MySQL"
SCRIPT_DESCRIPTION="Open-source relational database"
SCRIPT_CATEGORY="DATABASES"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="040-database-mysql.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n default -l app.kubernetes.io/name=mysql --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="040-remove-database-mysql.yml"
SCRIPT_REQUIRES=""
SCRIPT_PRIORITY="31"

# === Deployment Details (Optional) ===
SCRIPT_IMAGE="mysql:8.0"
SCRIPT_NAMESPACE="default"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Resource"        # Component | Resource
SCRIPT_TYPE="database"          # service | tool | library | database | cache | message-broker
SCRIPT_OWNER="platform-team"   # platform-team | app-team

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="Popular open-source relational database for web applications"
SCRIPT_LOGO="mysql-logo.svg"
SCRIPT_WEBSITE="https://www.mysql.com"
SCRIPT_TAGS="database,sql,relational,mysql,rdbms"
SCRIPT_SUMMARY="MySQL is the world's most popular open-source relational database management system. It powers many of the most accessed applications including Facebook, Twitter, and YouTube."
SCRIPT_DOCS="/docs/services/databases/mysql"

# === Template Integration (Optional) ===
SCRIPT_CONFIGURABLE="true"
SCRIPT_EXPOSE_PORT="33306"
