#!/bin/bash
# service-litellm.sh - LiteLLM service metadata
#
# LiteLLM provides a unified API for multiple LLM providers.

# === Service Metadata (Required) ===
SCRIPT_ID="litellm"
SCRIPT_NAME="LiteLLM"
SCRIPT_DESCRIPTION="Unified API gateway for LLM providers"
SCRIPT_CATEGORY="AI"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="210-setup-litellm.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n ai -l app.kubernetes.io/name=litellm --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="210-remove-litellm.yml"
SCRIPT_REQUIRES="postgresql"
SCRIPT_PRIORITY="51"

# === Deployment Details (Optional) ===
SCRIPT_HELM_CHART="oci://ghcr.io/berriai/litellm-helm"
SCRIPT_NAMESPACE="ai"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Component"        # Component | Resource
SCRIPT_TYPE="service"          # service | tool | library | database | cache | message-broker
SCRIPT_OWNER="app-team"   # platform-team | app-team
SCRIPT_PROVIDES_APIS="litellm-api"
SCRIPT_CONSUMES_APIS=""

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="Call 100+ LLM APIs using OpenAI format"
SCRIPT_LOGO="litellm-logo.svg"
SCRIPT_WEBSITE="https://litellm.ai"
SCRIPT_TAGS="ai,llm,api-gateway,openai,proxy,unified-api"
SCRIPT_SUMMARY="LiteLLM is a unified API gateway that allows you to call 100+ LLM APIs using the OpenAI format. It provides load balancing, fallbacks, spend tracking, and virtual keys."
SCRIPT_DOCS="/docs/services/ai/litellm"
