#!/bin/bash
# service-mongodb.sh - MongoDB service metadata
#
# MongoDB is a document-oriented NoSQL database.

# === Service Metadata (Required) ===
SCRIPT_ID="mongodb"
SCRIPT_NAME="MongoDB"
SCRIPT_DESCRIPTION="Document-oriented NoSQL database"
SCRIPT_CATEGORY="DATABASES"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="040-setup-mongodb.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n default -l app=mongodb --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="040-remove-database-mongodb.yml"
SCRIPT_REQUIRES=""
SCRIPT_PRIORITY="31"

# === Deployment Details (Optional) ===
SCRIPT_IMAGE="mongo:8.0.5"
SCRIPT_NAMESPACE="default"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Resource"        # Component | Resource
SCRIPT_TYPE="database"          # service | tool | library | database | cache | message-broker
SCRIPT_OWNER="platform-team"   # platform-team | app-team

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="General purpose document database"
SCRIPT_LOGO="mongodb-logo.svg"
SCRIPT_WEBSITE="https://www.mongodb.com"
SCRIPT_TAGS="database,nosql,document,json,flexible-schema"
SCRIPT_SUMMARY="MongoDB is a document-oriented NoSQL database designed for high-volume data storage. It stores data in flexible, JSON-like documents, meaning fields can vary from document to document."
SCRIPT_DOCS="/docs/services/databases/mongodb"

# === Template Integration (Optional) ===
SCRIPT_CONFIGURABLE="true"
SCRIPT_EXPOSE_PORT="37017"
