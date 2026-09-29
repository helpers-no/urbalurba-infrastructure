#!/bin/bash
# service-qdrant.sh - Qdrant service metadata
#
# Qdrant is a vector similarity search engine.

# === Service Metadata (Required) ===
SCRIPT_ID="qdrant"
SCRIPT_NAME="Qdrant"
SCRIPT_DESCRIPTION="Vector similarity search engine"
SCRIPT_CATEGORY="DATABASES"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="044-setup-qdrant.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n default -l app.kubernetes.io/name=qdrant --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="044-remove-qdrant.yml"
SCRIPT_REQUIRES=""
SCRIPT_PRIORITY="33"

# === Deployment Details (Optional) ===
SCRIPT_HELM_CHART="qdrant/qdrant"
SCRIPT_NAMESPACE="default"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Resource"        # Component | Resource
SCRIPT_TYPE="database"          # service | tool | library | database | cache | message-broker
SCRIPT_OWNER="platform-team"   # platform-team | app-team

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="High-performance vector database for AI applications"
SCRIPT_LOGO="qdrant-logo.svg"
SCRIPT_WEBSITE="https://qdrant.tech"
SCRIPT_TAGS="vector-database,ai,embeddings,similarity-search,semantic-search"
SCRIPT_SUMMARY="Qdrant is a vector similarity search engine and database designed for AI applications. It provides extended filtering support, making it useful for neural network or semantic-based matching."
SCRIPT_DOCS="/docs/services/databases/qdrant"

# === Template Integration (Optional) ===
# ⚠️ NOT configurable: there is no `lib/configure-qdrant.sh` handler, and the
# flag is what `uis configure` reads to decide whether to try. Declaring it
# true advertised a capability that produced "Handler not yet implemented"
# (urb-agents#1710, Terje 2026-09-29). Re-declare it the day a handler lands —
# a unit test now requires the two to agree.
SCRIPT_CONFIGURABLE="false"
SCRIPT_EXPOSE_PORT="36333"
