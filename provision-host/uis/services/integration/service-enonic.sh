#!/bin/bash
# service-enonic.sh - Enonic XP CMS service metadata
#
# Enonic XP is a headless CMS platform for content management and delivery.
# Used by Norwegian organizations (NAV, Gjensidige, Helsedirektoratet).

# === Service Metadata (Required) ===
SCRIPT_ID="enonic"
SCRIPT_NAME="Enonic XP"
SCRIPT_DESCRIPTION="Headless CMS platform for content management and delivery"
SCRIPT_CATEGORY="INTEGRATION"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="085-setup-enonic.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n enonic -l app=enonic-xp --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="085-remove-enonic.yml"
SCRIPT_REQUIRES=""
SCRIPT_PRIORITY="85"

# === Deployment Details (Optional) ===
SCRIPT_IMAGE="enonic/xp:7.16.2-ubuntu"
SCRIPT_HELM_CHART=""
SCRIPT_NAMESPACE="enonic"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Component"        # Component | Resource
SCRIPT_TYPE="service"          # service | tool | library | database | cache | message-broker
SCRIPT_OWNER="app-team"   # platform-team | app-team

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="Headless CMS platform with embedded storage, Content Studio, and 100+ integrations"
SCRIPT_LOGO="enonic-logo.svg"
SCRIPT_WEBSITE="https://enonic.com"
SCRIPT_TAGS="cms,headless-cms,content-management,content-studio,graphql,enonic-xp"
SCRIPT_SUMMARY="Enonic XP is a Java/GraalVM-based headless CMS platform with embedded Elasticsearch and NoSQL storage. It provides Content Studio for editorial work, headless APIs (GraphQL/REST), and a composable architecture for building content-driven applications."
SCRIPT_DOCS="/docs/services/integration/enonic"
