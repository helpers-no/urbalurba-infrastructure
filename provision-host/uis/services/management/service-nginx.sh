#!/bin/bash
# service-nginx.sh - Nginx service metadata
#
# Nginx provides static file serving and reverse proxy capabilities.
# Default service deployed with UIS.

# === Service Metadata (Required) ===
SCRIPT_ID="nginx"
SCRIPT_NAME="Nginx"
SCRIPT_DESCRIPTION="Web server and reverse proxy"
SCRIPT_CATEGORY="MANAGEMENT"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="020-setup-nginx.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n default -l app.kubernetes.io/name=nginx --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="020-remove-nginx.yml"
SCRIPT_REQUIRES=""
SCRIPT_PRIORITY="1"

# === Deployment Details (Optional) ===
SCRIPT_HELM_CHART="bitnami/nginx"
SCRIPT_NAMESPACE="default"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Component"        # Component | Resource
SCRIPT_TYPE="service"          # service | tool | library | database | cache | message-broker
SCRIPT_OWNER="platform-team"   # platform-team | app-team

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="High-performance web server and reverse proxy"
SCRIPT_LOGO="nginx-logo.svg"
SCRIPT_WEBSITE="https://nginx.org"
SCRIPT_TAGS="webserver,proxy,reverse-proxy,load-balancer,http"
SCRIPT_SUMMARY="Nginx is a high-performance HTTP server and reverse proxy, known for its stability, rich feature set, simple configuration, and low resource consumption."
SCRIPT_DOCS="/docs/services/management/nginx"
