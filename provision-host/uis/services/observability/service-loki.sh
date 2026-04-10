#!/bin/bash
# service-loki.sh - Loki service metadata
#
# Loki is a log aggregation system designed to work with Grafana.
# Part of the observability stack.

# === Service Metadata (Required) ===
SCRIPT_ID="loki"
SCRIPT_NAME="Loki"
SCRIPT_DESCRIPTION="Log aggregation and storage"
SCRIPT_CATEGORY="OBSERVABILITY"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="032-setup-loki.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n monitoring -l app.kubernetes.io/name=loki --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="032-remove-loki.yml"
SCRIPT_REQUIRES=""
SCRIPT_PRIORITY="11"

# === Deployment Details (Optional) ===
SCRIPT_HELM_CHART="grafana/loki"
SCRIPT_NAMESPACE="monitoring"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Component"        # Component | Resource
SCRIPT_TYPE="service"          # service | tool | library | database | cache | message-broker
SCRIPT_OWNER="platform-team"   # platform-team | app-team

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="Horizontally-scalable log aggregation system"
SCRIPT_LOGO="loki-logo.png"
SCRIPT_WEBSITE="https://grafana.com/oss/loki/"
SCRIPT_TAGS="logging,logs,aggregation,observability,monitoring"
SCRIPT_SUMMARY="Loki is a horizontally-scalable, highly-available, multi-tenant log aggregation system inspired by Prometheus. It indexes labels, not log content, making it cost-effective and easy to operate."
SCRIPT_DOCS="/docs/services/observability/loki"
