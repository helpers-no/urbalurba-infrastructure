#!/bin/bash
# service-otel-collector.sh - OpenTelemetry Collector service metadata
#
# OpenTelemetry Collector receives, processes, and exports telemetry data.
# Part of the observability stack.

# === Service Metadata (Required) ===
SCRIPT_ID="otel-collector"
SCRIPT_NAME="OpenTelemetry Collector"
SCRIPT_DESCRIPTION="Telemetry data collection and processing"
SCRIPT_CATEGORY="OBSERVABILITY"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="033-setup-otel-collector.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n monitoring -l app.kubernetes.io/name=opentelemetry-collector --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="033-remove-otel-collector.yml"
SCRIPT_REQUIRES="prometheus loki tempo"
SCRIPT_PRIORITY="13"

# === Deployment Details (Optional) ===
SCRIPT_HELM_CHART="open-telemetry/opentelemetry-collector"
SCRIPT_NAMESPACE="monitoring"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Component"        # Component | Resource
SCRIPT_TYPE="service"          # service | tool | library | database | cache | message-broker
SCRIPT_OWNER="platform-team"   # platform-team | app-team

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="Vendor-agnostic telemetry collection and processing"
SCRIPT_LOGO="otel-collector-logo.svg"
SCRIPT_WEBSITE="https://opentelemetry.io"
SCRIPT_TAGS="telemetry,opentelemetry,otel,observability,traces,metrics,logs"
SCRIPT_SUMMARY="The OpenTelemetry Collector offers a vendor-agnostic implementation to receive, process, and export telemetry data. It removes the need to run multiple agents/collectors."
SCRIPT_DOCS="/docs/services/observability/otel-collector"
