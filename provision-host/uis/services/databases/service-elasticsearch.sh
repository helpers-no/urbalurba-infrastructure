#!/bin/bash
# service-elasticsearch.sh - Elasticsearch service metadata
#
# Elasticsearch is a distributed search and analytics engine.

# === Service Metadata (Required) ===
SCRIPT_ID="elasticsearch"
SCRIPT_NAME="Elasticsearch"
SCRIPT_DESCRIPTION="Distributed search and analytics engine"
SCRIPT_CATEGORY="DATABASES"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="060-setup-elasticsearch.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n default -l app=elasticsearch-master --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="060-remove-elasticsearch.yml"
SCRIPT_REQUIRES=""
SCRIPT_PRIORITY="70"

# === Deployment Details (Optional) ===
SCRIPT_HELM_CHART="elastic/elasticsearch"
SCRIPT_NAMESPACE="default"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Resource"        # Component | Resource
SCRIPT_TYPE="database"          # service | tool | library | database | cache | message-broker
SCRIPT_OWNER="platform-team"   # platform-team | app-team

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="RESTful search and analytics engine for all types of data"
SCRIPT_LOGO="elasticsearch-logo.svg"
SCRIPT_WEBSITE="https://www.elastic.co/elasticsearch"
SCRIPT_TAGS="search,full-text,analytics,indexing,distributed"
SCRIPT_SUMMARY="Elasticsearch is a distributed, RESTful search and analytics engine capable of addressing a growing number of use cases. It centrally stores your data for lightning fast search and fine-tuned relevancy."
SCRIPT_DOCS="/docs/services/databases/elasticsearch"

# === Template Integration (Optional) ===
# ⚠️ NOT configurable: there is no `lib/configure-elasticsearch.sh` handler, and the
# flag is what `uis configure` reads to decide whether to try. Declaring it
# true advertised a capability that produced "Handler not yet implemented"
# (urb-agents#1710, Terje 2026-09-29). Re-declare it the day a handler lands —
# a unit test now requires the two to agree.
SCRIPT_CONFIGURABLE="false"
SCRIPT_EXPOSE_PORT="39200"
