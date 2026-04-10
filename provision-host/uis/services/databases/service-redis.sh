#!/bin/bash
# service-redis.sh - Redis service metadata
#
# Redis is an in-memory data store used as cache and message broker.

# === Service Metadata (Required) ===
SCRIPT_ID="redis"
SCRIPT_NAME="Redis"
SCRIPT_DESCRIPTION="In-memory data store and cache"
SCRIPT_CATEGORY="DATABASES"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="050-setup-redis.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n default -l app.kubernetes.io/name=redis --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="050-remove-redis.yml"
SCRIPT_REQUIRES=""
SCRIPT_PRIORITY="32"

# === Deployment Details (Optional) ===
SCRIPT_HELM_CHART="bitnami/redis"
SCRIPT_NAMESPACE="default"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Resource"        # Component | Resource
SCRIPT_TYPE="cache"          # service | tool | library | database | cache | message-broker
SCRIPT_OWNER="platform-team"   # platform-team | app-team

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="In-memory data structure store for caching and messaging"
SCRIPT_LOGO="redis-logo.svg"
SCRIPT_WEBSITE="https://redis.io"
SCRIPT_TAGS="cache,in-memory,key-value,message-broker,session"
SCRIPT_SUMMARY="Redis is an open-source, in-memory data structure store used as a database, cache, message broker, and streaming engine. It supports various data structures like strings, hashes, lists, and sets."
SCRIPT_DOCS="/docs/services/databases/redis"

# === Template Integration (Optional) ===
SCRIPT_CONFIGURABLE="true"
SCRIPT_EXPOSE_PORT="36379"
