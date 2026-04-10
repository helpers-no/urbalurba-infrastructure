#!/bin/bash
# service-openwebui.sh - Open WebUI service metadata
#
# Open WebUI provides a user-friendly interface for AI models.

# === Service Metadata (Required) ===
SCRIPT_ID="openwebui"
SCRIPT_NAME="Open WebUI"
SCRIPT_DESCRIPTION="User-friendly interface for AI models"
SCRIPT_CATEGORY="AI"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="200-setup-open-webui.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n ai -l app.kubernetes.io/name=open-webui --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="200-remove-open-webui.yml"
SCRIPT_REQUIRES="postgresql"
SCRIPT_PRIORITY="50"

# === Deployment Details (Optional) ===
SCRIPT_HELM_CHART="open-webui/open-webui"
SCRIPT_NAMESPACE="ai"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Component"        # Component | Resource
SCRIPT_TYPE="service"          # service | tool | library | database | cache | message-broker
SCRIPT_OWNER="app-team"   # platform-team | app-team
SCRIPT_PROVIDES_APIS="openwebui-api"
SCRIPT_CONSUMES_APIS="litellm-api"

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="Self-hosted AI interface supporting multiple model providers"
SCRIPT_LOGO="openwebui-logo.png"
SCRIPT_WEBSITE="https://openwebui.com"
SCRIPT_TAGS="ai,llm,chat,interface,openai,ollama"
SCRIPT_SUMMARY="Open WebUI is an extensible, feature-rich, and user-friendly self-hosted AI interface. It supports various LLM runners including Ollama and OpenAI-compatible APIs."
SCRIPT_DOCS="/docs/services/ai/openwebui"
