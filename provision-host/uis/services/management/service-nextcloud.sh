#!/bin/bash
# service-nextcloud.sh - Nextcloud service metadata
#
# Nextcloud is a self-hosted collaboration platform with file sync,
# document editing (via OnlyOffice), calendar, contacts, and more.

# === Service Metadata (Required) ===
SCRIPT_ID="nextcloud"
SCRIPT_NAME="Nextcloud"
SCRIPT_DESCRIPTION="Self-hosted collaboration platform with file sync and document editing"
SCRIPT_CATEGORY="APPLICATIONS"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="620-setup-nextcloud.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n nextcloud -l app.kubernetes.io/name=nextcloud --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="620-remove-nextcloud.yml"
SCRIPT_REQUIRES="postgresql redis"
SCRIPT_PRIORITY="620"

# === Deployment Details (Optional) ===
SCRIPT_IMAGE="nextcloud:33-apache"
SCRIPT_HELM_CHART="nextcloud/nextcloud"
SCRIPT_NAMESPACE="nextcloud"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Component"        # Component | Resource
SCRIPT_TYPE="service"          # service | tool | library | database | cache | message-broker
SCRIPT_OWNER="app-team"   # platform-team | app-team

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="Self-hosted collaboration platform — file sync, document editing, calendar, and contacts"
SCRIPT_LOGO="nextcloud-logo.svg"
SCRIPT_WEBSITE="https://nextcloud.com"
SCRIPT_TAGS="collaboration,file-sync,document-editing,calendar,contacts,onlyoffice"
SCRIPT_SUMMARY="Nextcloud is a self-hosted content collaboration platform providing file sync and sharing, browser-based document editing via OnlyOffice, calendar, contacts, and more. Deployed with the official Helm chart, reusing existing UIS PostgreSQL and Redis services."
SCRIPT_DOCS="/docs/services/applications/nextcloud"
