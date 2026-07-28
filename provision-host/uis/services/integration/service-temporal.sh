#!/bin/bash
# service-temporal.sh - Temporal service metadata
#
# Temporal is a durable workflow engine. Application code registers Workflows and
# Activities with the cluster; Temporal persists every state transition so the code
# survives process crashes, pod restarts and redeploys, and retries failed steps
# with the policy the code declares.
#
# UIS shape: PostgreSQL-only. Both the history store and the visibility store live
# in the SHARED UIS PostgreSQL (databases `temporal` and `temporal_visibility`).
# Elasticsearch and Cassandra are deliberately NOT deployed - Temporal 1.20+ does
# advanced visibility on PostgreSQL 12+, which keeps a laptop cluster small.
# See manifests/086-temporal-config.yaml for the rationale in full.

# === Service Metadata (Required) ===
SCRIPT_ID="temporal"
SCRIPT_NAME="Temporal"
SCRIPT_DESCRIPTION="Durable workflow orchestration engine"
SCRIPT_CATEGORY="INTEGRATION"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="086-setup-temporal.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n temporal -l app.kubernetes.io/component=frontend --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="086-remove-temporal.yml"
SCRIPT_REQUIRES="postgresql"
SCRIPT_PRIORITY="55"

# === Deployment Details (Optional) ===
# Chart version is pinned in 086-setup-temporal.yml. temporal/temporal 1.6.0 ships
# server + admintools 1.31.2 and UI 2.52.0. SCRIPT_IMAGE is informational only -
# the chart pulls temporalio/server, temporalio/admin-tools and temporalio/ui.
SCRIPT_IMAGE="temporalio/server:1.31.2"
SCRIPT_HELM_CHART="temporal/temporal"
SCRIPT_NAMESPACE="temporal"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Component"         # Component | Resource
SCRIPT_TYPE="service"           # service | tool | library | database | cache | message-broker
SCRIPT_OWNER="platform-team"    # platform-team | app-team
SCRIPT_PROVIDES_APIS="temporal-api"
SCRIPT_CONSUMES_APIS="postgresql"

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="Durable execution engine that runs long-lived workflows reliably across crashes and restarts"
SCRIPT_LOGO="temporal-logo.svg"
SCRIPT_WEBSITE="https://temporal.io"
SCRIPT_TAGS="workflow,orchestration,durable-execution,saga,background-jobs,postgresql"
SCRIPT_SUMMARY="Temporal is an open-source durable execution platform. Workflows are written as ordinary code in Go, TypeScript, Python, Java, .NET or PHP; the Temporal cluster records every state transition so a workflow resumes exactly where it left off after a crash, a deploy, or a multi-day wait. UIS deploys the official Helm chart with the shared UIS PostgreSQL as both the history and the visibility store - no Elasticsearch and no Cassandra - plus the Temporal Web UI behind Traefik at temporal.localhost."
SCRIPT_DOCS="/docs/services/integration/temporal"

# === Template Integration (Optional) ===
# The gRPC frontend is what SDK clients and workers connect to
# (./uis expose temporal -> localhost:37233). The Web UI is reached
# through Traefik at http://temporal.localhost instead.
SCRIPT_EXPOSE_PORT="37233"
