#!/bin/bash
# service-gravitee.sh - Gravitee API Gateway service metadata
#
# Gravitee is an open-source API management platform.

# === Service Metadata (Required) ===
SCRIPT_ID="gravitee"
SCRIPT_NAME="Gravitee"
SCRIPT_DESCRIPTION="API management and gateway platform"
SCRIPT_CATEGORY="INTEGRATION"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="090-setup-gravitee.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n gravitee -l app.kubernetes.io/name=gravitee --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK=""
SCRIPT_REQUIRES=""
SCRIPT_PRIORITY="81"

# === Deployment Details (Optional) ===
SCRIPT_HELM_CHART="graviteeio/apim"
SCRIPT_NAMESPACE="default"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Component"        # Component | Resource
SCRIPT_TYPE="service"          # service | tool | library | database | cache | message-broker
SCRIPT_OWNER="app-team"   # platform-team | app-team
SCRIPT_PROVIDES_APIS="gravitee-api"
SCRIPT_CONSUMES_APIS=""

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="Open-source API management platform for designing, deploying, and managing APIs"
SCRIPT_LOGO="gravitee-logo.svg"
SCRIPT_WEBSITE="https://www.gravitee.io"
SCRIPT_TAGS="api-gateway,api-management,rest,graphql,security"
SCRIPT_SUMMARY="Gravitee is an open-source API management platform that helps you design, deploy, and manage APIs. It provides a gateway, management console, and developer portal for comprehensive API lifecycle management."
SCRIPT_DOCS="/docs/services/integration/gravitee"
