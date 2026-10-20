#!/bin/bash
# service-epinio.sh - Epinio service metadata
#
# Epinio is a self-service "push code, get a URL" deploy path — build and deploy from source,
# with no Kubernetes manifest and no kubeconfig for the developer. A third UIS deploy mechanism
# alongside `uis` provisioning and ArgoCD — see
# website/docs/ai-developer/plans/backlog/INVESTIGATE-service-epinio-deploy-path.md.
#
# PLAN-service-epinio-001 scope only: install with Epinio's own bundled defaults (basic auth,
# bundled object storage/registry). Identity (Dex/OIDC) and this platform's own object
# store/registry wiring are later PLANs, not this one.

# === Service Metadata (Required) ===
SCRIPT_ID="epinio"
SCRIPT_NAME="Epinio"
SCRIPT_DESCRIPTION="Self-service source-to-URL deploy path (push code, get a URL, no kubeconfig)"
SCRIPT_CATEGORY="MANAGEMENT"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="625-setup-epinio.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n epinio -l app.kubernetes.io/name=epinio-server --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="625-remove-epinio.yml"
SCRIPT_REQUIRES="cert-manager"
SCRIPT_PRIORITY="85"

# === Deployment Details (Optional) ===
SCRIPT_HELM_CHART="epinio/epinio"
SCRIPT_NAMESPACE="epinio"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Component"        # Component | Resource
SCRIPT_TYPE="tool"          # service | tool | library | database | cache | message-broker
SCRIPT_OWNER="platform-team"   # platform-team | app-team

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="Push code, get a URL — Heroku/Vercel-style self-service deploy"
SCRIPT_LOGO=""
SCRIPT_WEBSITE="https://epinio.io"
SCRIPT_TAGS="paas,deploy,buildpacks,self-service,kubernetes"
SCRIPT_SUMMARY="Epinio builds and deploys an application directly from source — no Kubernetes manifest, no kubeconfig for the developer. Alongside ArgoCD (which deploys a manifest the application brings) and uis (which provisions platform services), Epinio is UIS's third deploy mechanism: for code that brings neither."
SCRIPT_DOCS="/docs/services/management/epinio"
