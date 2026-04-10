#!/bin/bash
# service-redisinsight.sh - RedisInsight service metadata
#
# RedisInsight is a web-based GUI for Redis database management.

# === Service Metadata (Required) ===
SCRIPT_ID="redisinsight"
SCRIPT_NAME="RedisInsight"
SCRIPT_DESCRIPTION="Web-based Redis database management GUI"
SCRIPT_CATEGORY="MANAGEMENT"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="651-adm-redisinsight.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n default -l app.kubernetes.io/name=redisinsight --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="651-remove-redisinsight.yml"
SCRIPT_REQUIRES="redis"
SCRIPT_PRIORITY="90"

# === Deployment Details (Optional) ===
SCRIPT_HELM_CHART="redisinsight/redisinsight"
SCRIPT_NAMESPACE="default"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Component"        # Component | Resource
SCRIPT_TYPE="tool"          # service | tool | library | database | cache | message-broker
SCRIPT_OWNER="platform-team"   # platform-team | app-team

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="Visual management interface for Redis"
SCRIPT_LOGO="redisinsight-logo.svg"
SCRIPT_WEBSITE="https://redis.io/insight/"
SCRIPT_TAGS="redis,database,admin,management,web-ui,cache"
SCRIPT_SUMMARY="RedisInsight is a visual tool for managing Redis databases. It provides a graphical interface for browsing keys, running commands, monitoring performance, and managing Redis data structures."
SCRIPT_DOCS="/docs/services/management/redisinsight"
