#!/bin/bash
# service-whoami.sh - Whoami test service metadata
#
# Whoami is a simple test container that returns request information.

# === Service Metadata (Required) ===
SCRIPT_ID="whoami"
SCRIPT_NAME="Whoami"
SCRIPT_DESCRIPTION="Test service for debugging"
SCRIPT_CATEGORY="MANAGEMENT"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="025-setup-whoami-testpod.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n default -l app=whoami --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="025-setup-whoami-testpod.yml -e operation=delete"
SCRIPT_REQUIRES=""
SCRIPT_PRIORITY="2"

# === Deployment Details (Optional) ===
SCRIPT_IMAGE="traefik/whoami:v1.10.2"
SCRIPT_NAMESPACE="default"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Component"        # Component | Resource
SCRIPT_TYPE="tool"          # service | tool | library | database | cache | message-broker
SCRIPT_OWNER="platform-team"   # platform-team | app-team

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="Lightweight test container for debugging ingress and authentication"
SCRIPT_LOGO="whoami-logo.svg"
SCRIPT_WEBSITE="https://github.com/traefik/whoami"
SCRIPT_TAGS="testing,debug,ingress,traefik,development"
SCRIPT_SUMMARY="Whoami is a tiny Go webserver that prints OS information and HTTP request details. It's useful for testing ingress configurations, authentication flows, and debugging network issues."
SCRIPT_DOCS="/docs/services/management/whoami"
