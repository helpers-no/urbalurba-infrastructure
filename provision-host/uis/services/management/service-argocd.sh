#!/bin/bash
# service-argocd.sh - ArgoCD service metadata
#
# ArgoCD is a GitOps continuous delivery tool for Kubernetes.

# === Service Metadata (Required) ===
SCRIPT_ID="argocd"
SCRIPT_NAME="ArgoCD"
SCRIPT_DESCRIPTION="GitOps continuous delivery for Kubernetes"
SCRIPT_CATEGORY="MANAGEMENT"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="220-setup-argocd.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="220-remove-argocd.yml"
SCRIPT_REQUIRES=""
SCRIPT_PRIORITY="80"

# === Deployment Details (Optional) ===
SCRIPT_HELM_CHART="argo/argo-cd"
SCRIPT_NAMESPACE="argocd"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Component"        # Component | Resource
SCRIPT_TYPE="tool"          # service | tool | library | database | cache | message-broker
SCRIPT_OWNER="platform-team"   # platform-team | app-team

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="Declarative GitOps CD for Kubernetes"
SCRIPT_LOGO="argocd-logo.svg"
SCRIPT_WEBSITE="https://argo-cd.readthedocs.io"
SCRIPT_TAGS="gitops,cd,continuous-delivery,kubernetes,deployment"
SCRIPT_SUMMARY="ArgoCD is a declarative, GitOps continuous delivery tool for Kubernetes. It automates the deployment of applications to specified target environments, keeping them synchronized with their Git repository definitions."
SCRIPT_DOCS="/docs/services/management/argocd"
