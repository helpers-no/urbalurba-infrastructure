#!/bin/bash
# service-rabbitmq.sh - RabbitMQ service metadata
#
# RabbitMQ is a message broker for async communication.

# === Service Metadata (Required) ===
SCRIPT_ID="rabbitmq"
SCRIPT_NAME="RabbitMQ"
SCRIPT_DESCRIPTION="Message broker for async communication"
SCRIPT_CATEGORY="INTEGRATION"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="080-setup-rabbitmq.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n default -l app.kubernetes.io/name=rabbitmq --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="080-remove-rabbitmq.yml"
SCRIPT_REQUIRES=""
SCRIPT_PRIORITY="60"

# === Deployment Details (Optional) ===
SCRIPT_HELM_CHART="bitnami/rabbitmq"
SCRIPT_NAMESPACE="default"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Resource"        # Component | Resource
SCRIPT_TYPE="message-broker"          # service | tool | library | database | cache | message-broker
SCRIPT_OWNER="platform-team"   # platform-team | app-team

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="Reliable message broker supporting multiple messaging protocols"
SCRIPT_LOGO="rabbitmq-logo.svg"
SCRIPT_WEBSITE="https://www.rabbitmq.com"
SCRIPT_TAGS="message-queue,amqp,messaging,async,pubsub"
SCRIPT_SUMMARY="RabbitMQ is a reliable and mature messaging broker that supports multiple messaging protocols including AMQP. It provides features like message persistence, delivery acknowledgment, and flexible routing."
SCRIPT_DOCS="/docs/services/integration/rabbitmq"
