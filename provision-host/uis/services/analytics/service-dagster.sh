#!/bin/bash
# service-dagster.sh - Dagster service metadata
#
# Dagster is the UIS DATA-ASSET orchestrator: scheduling, lineage, freshness and
# backfills for data pipelines, with a dbt-native asset graph.
#
# ⚠️ UIS also ships Temporal. They are NOT alternatives:
#     Temporal  → durable execution. A workflow resumes mid-step after a crash.
#     Dagster   → data assets. Lineage, freshness, dbt, backfills.
#   Neither has the other's core concept. The platform rule is: at most ONE
#   orchestrator per shape. See website/docs/services/analytics/dagster.md.

# === Service Metadata (Required) ===
SCRIPT_ID="dagster"
SCRIPT_NAME="Dagster"
SCRIPT_DESCRIPTION="Data-asset orchestrator with lineage, freshness and dbt-native pipelines"
SCRIPT_CATEGORY="ANALYTICS"

# === Deployment (Required) ===
SCRIPT_PLAYBOOK="360-setup-dagster.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n dagster -l app.kubernetes.io/instance=dagster --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="360-remove-dagster.yml"
SCRIPT_REQUIRES="postgresql"
SCRIPT_PRIORITY="56"

# === Deployment Details (Optional) ===
SCRIPT_HELM_CHART="dagster/dagster"
SCRIPT_NAMESPACE="dagster"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Component"        # Component | Resource
SCRIPT_TYPE="service"          # service | tool | library | database | cache | message-broker
SCRIPT_OWNER="platform-team"   # platform-team | app-team
SCRIPT_PROVIDES_APIS="dagster-graphql"
SCRIPT_CONSUMES_APIS="postgresql"

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="Orchestrates data pipelines as assets — scheduling, lineage, freshness and dbt"
SCRIPT_LOGO="dagster-logo.svg"
SCRIPT_WEBSITE="https://dagster.io/"
SCRIPT_TAGS="orchestration,data,pipelines,dbt,etl,scheduling,lineage,analytics"
SCRIPT_SUMMARY="Dagster is a data orchestrator built around assets rather than tasks: you declare the tables, files and models your pipelines produce, and Dagster schedules them, tracks their lineage and freshness, and re-materialises what is stale. Applications register with the platform as code locations, and dagster-pipes lets a code location be written in any language - so a TypeScript ingest and a dbt project can sit in one asset graph. UIS ships it alongside Temporal, which solves a different problem: Temporal orchestrates durable processes, Dagster orchestrates data."
SCRIPT_DOCS="/docs/services/analytics/dagster"
