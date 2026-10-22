#!/bin/bash
# service-external-secrets.sh - External Secrets Operator (ESO) service metadata
#
# ESO is the prerequisite for OpenBao (service-bao.sh) and for any future
# ExternalSecret-backed secret store: a developer's ExternalSecret manifest must be
# byte-identical to production's, and that only means something once ESO's own
# CRDs/controller exist in the cluster. See
# website/docs/ai-developer/plans/backlog/INVESTIGATE-service-openbao.md Part 2b/Q5 -
# "this makes ESO ... the component that must become a UIS service first."
#
# This service installs ESO itself only - no ClusterSecretStore. Each store (bao's
# "openbao" store, and any future one) is that consuming service's own concern,
# the same way platforms/proxmox's k3s-bao-ensure.yml (ESO + the "openbao" store,
# proven against real hardware) keeps them separate.

# === Service Metadata (Required) ===
SCRIPT_ID="external-secrets"
SCRIPT_NAME="External Secrets Operator"
SCRIPT_DESCRIPTION="Syncs Kubernetes Secrets from external secret stores via ExternalSecret/ClusterSecretStore"
SCRIPT_CATEGORY="MANAGEMENT"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="026-setup-external-secrets.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n external-secrets -l app.kubernetes.io/name=external-secrets --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="026-remove-external-secrets.yml"
SCRIPT_REQUIRES=""
SCRIPT_PRIORITY="21"

# === Deployment Details (Optional) ===
SCRIPT_HELM_CHART="external-secrets/external-secrets"
SCRIPT_NAMESPACE="external-secrets"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Component"        # Component | Resource
SCRIPT_TYPE="tool"              # service | tool | library | database | cache | message-broker
SCRIPT_OWNER="platform-team"    # platform-team | app-team

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="Syncs Kubernetes Secrets from an external secret store, via the ExternalSecret API"
SCRIPT_LOGO=""
SCRIPT_WEBSITE="https://external-secrets.io"
SCRIPT_TAGS="secrets,eso,vault,kubernetes"
SCRIPT_SUMMARY="External Secrets Operator (ESO) reads ExternalSecret resources and materialises them as ordinary Kubernetes Secrets, sourced from a named ClusterSecretStore. UIS installs the operator itself only - the store a consuming service needs (e.g. OpenBao's 'openbao' store) is that service's own concern, so the same ExternalSecret a developer writes here resolves identically in production."
SCRIPT_DOCS="/docs/services/management/external-secrets"
