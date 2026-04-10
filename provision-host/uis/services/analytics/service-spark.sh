#!/bin/bash
# service-spark.sh - Apache Spark service metadata
#
# Apache Spark is a unified analytics engine for large-scale data processing.

# === Service Metadata (Required) ===
SCRIPT_ID="spark"
SCRIPT_NAME="Apache Spark"
SCRIPT_DESCRIPTION="Unified analytics engine for big data"
SCRIPT_CATEGORY="ANALYTICS"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="330-setup-spark.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n spark-operator -l app.kubernetes.io/name=spark-kubernetes-operator --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="330-remove-spark.yml"
SCRIPT_REQUIRES=""
SCRIPT_PRIORITY="91"

# === Deployment Details (Optional) ===
SCRIPT_HELM_CHART="spark-kubernetes-operator/spark-kubernetes-operator"
SCRIPT_NAMESPACE="spark-operator"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Component"        # Component | Resource
SCRIPT_TYPE="service"          # service | tool | library | database | cache | message-broker
SCRIPT_OWNER="app-team"   # platform-team | app-team

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="Fast and general-purpose cluster computing system for big data processing"
SCRIPT_LOGO="spark-logo.svg"
SCRIPT_WEBSITE="https://spark.apache.org"
SCRIPT_TAGS="big-data,analytics,distributed-computing,etl,machine-learning"
SCRIPT_SUMMARY="Apache Spark is a unified analytics engine for large-scale data processing. It provides high-level APIs in Java, Scala, Python, and R, and supports SQL queries, streaming data, machine learning, and graph processing."
SCRIPT_DOCS="/docs/services/analytics/spark"
