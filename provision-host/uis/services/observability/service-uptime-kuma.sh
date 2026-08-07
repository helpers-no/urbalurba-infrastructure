#!/bin/bash
# service-uptime-kuma.sh - Uptime Kuma metadata
#
# ⚠️ READ THIS BEFORE DEPLOYING
# Uptime Kuma is an EXTERNAL watchdog. It is only useful on a host that is NOT
# part of the platform it monitors: a monitor inside a cluster cannot report
# that cluster being down, which is the entire reason it exists.
# UIS cannot express "deploy this somewhere else", so the constraint is stated
# here, in the docs page and in the deploy output. Deploying it onto the cluster
# it is meant to watch will appear to work and will be useless in the one
# situation you need it.
# See website/docs/ai-developer/plans/backlog/INVESTIGATE-service-uptime-kuma.md

# === Service Metadata (Required) ===
SCRIPT_ID="uptime-kuma"
SCRIPT_NAME="Uptime Kuma"
SCRIPT_DESCRIPTION="External availability watchdog - deploy OUTSIDE the cluster it monitors"
SCRIPT_CATEGORY="OBSERVABILITY"

# === Deployment (Required) ===
SCRIPT_PLAYBOOK="230-setup-uptime-kuma.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n monitoring -l app=uptime-kuma --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="230-remove-uptime-kuma.yml"
SCRIPT_REQUIRES=""
SCRIPT_PRIORITY="30"

# === Deployment Details (Optional) ===
SCRIPT_IMAGE="louislam/uptime-kuma:2.5.0"
SCRIPT_HELM_CHART=""
SCRIPT_NAMESPACE="monitoring"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Component"
SCRIPT_TYPE="service"
SCRIPT_OWNER="platform-team"
SCRIPT_PROVIDES_APIS=""
SCRIPT_CONSUMES_APIS=""

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="Self-hosted uptime monitoring with HTTP, TCP, ping and push-heartbeat checks, and ~90 notification channels"
SCRIPT_SUMMARY="Uptime Kuma answers 'is it up, and did the job run?' from outside the platform. It complements rather than replaces an in-cluster metrics stack: Prometheus and Grafana explain why something is behaving badly, but they die with the cluster they run in. Uptime Kuma also provides push/heartbeat monitors, which detect the absence of expected work - a stalled pipeline or a backup that silently stopped - that metric-based alerting handles poorly. Deploy it on a host that is not part of the platform it watches."
SCRIPT_LOGO="uptime-kuma-logo.svg"
SCRIPT_WEBSITE="https://uptime.kuma.pet"
SCRIPT_TAGS="monitoring,uptime,availability,watchdog,heartbeat,alerting,status-page"
SCRIPT_DOCS="/docs/services/observability/uptime-kuma"
