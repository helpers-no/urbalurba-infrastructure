#!/bin/bash
# Grafana Alloy - log collection agent.
#
# Ships container logs into Loki. Without it Loki is deployed, healthy and empty:
# it holds only its own canary traffic, and Grafana's Loki datasource returns
# nothing useful.
#
# Deliberately a separate service from Loki: Loki is the store, Alloy is the
# collector, and an installation may reasonably run one without the other.

# === Service Metadata (Required) ===
SCRIPT_ID="alloy"
SCRIPT_NAME="Grafana Alloy"
SCRIPT_DESCRIPTION="Collects container logs and ships them to Loki"
SCRIPT_CATEGORY="OBSERVABILITY"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="031-setup-alloy.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n monitoring -l app.kubernetes.io/name=alloy --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="031-remove-alloy.yml"
SCRIPT_REQUIRES="loki"
SCRIPT_PRIORITY="12"

# === Deployment Details (Optional) ===
SCRIPT_HELM_CHART="grafana/alloy"
SCRIPT_NAMESPACE="monitoring"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Component"        # Component | Resource
SCRIPT_TYPE="service"          # service | tool | library | database | cache | message-broker
SCRIPT_OWNER="platform-team"   # platform-team | app-team

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="Log collection agent that ships container logs into Loki"
SCRIPT_LOGO="alloy-logo.svg"
SCRIPT_WEBSITE="https://grafana.com/oss/alloy/"
SCRIPT_TAGS="logging,logs,collector,agent,observability,monitoring"
SCRIPT_SUMMARY="Grafana Alloy is an OpenTelemetry Collector distribution that discovers every pod in the cluster, tails its container logs, labels them with their Kubernetes metadata, and forwards them to Loki. It is what makes the Loki datasource in Grafana return anything at all - deploy Loki without it and the store stays empty."
SCRIPT_DOCS="/docs/services/observability/alloy"
