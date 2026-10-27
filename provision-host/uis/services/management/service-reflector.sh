#!/bin/bash
# service-reflector.sh - kubernetes-reflector service metadata
#
# Mirrors an annotated Secret (or ConfigMap) from one namespace into others, kept in
# sync automatically on every change - the piece UIS was missing for a cert-manager
# Certificate issued in one namespace to be trusted by a workload in another. First
# consumer: Epinio's Dex connector (epinio namespace) trusting Authentik's own TLS
# certificate (authentik namespace) - see urb-agents#2040/service-epinio.sh.

# === Service Metadata (Required) ===
SCRIPT_ID="reflector"
SCRIPT_NAME="Reflector"
SCRIPT_DESCRIPTION="Mirrors a Secret/ConfigMap across namespaces, kept in sync automatically"
SCRIPT_CATEGORY="MANAGEMENT"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="028-setup-reflector.yml"
SCRIPT_MANIFEST=""
# 🔴 CLUSTER-WIDE (-A), not scoped to the "reflector" namespace — found live (urb-agents#2044):
# reflector has no release-scoped RBAC, and Epinio's own Helm chart already bundles the same
# chart as a subchart dependency. 028-setup-reflector.yml detects that and skips installing a
# second one; this check must agree, or `uis status`/`uis deploy` would report "not deployed"
# even though the capability this service exists for is already satisfied.
SCRIPT_CHECK_COMMAND="kubectl get pods -A -l app.kubernetes.io/name=reflector --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="028-remove-reflector.yml"
SCRIPT_REQUIRES=""
SCRIPT_PRIORITY="23"

# === Deployment Details (Optional) ===
SCRIPT_HELM_CHART="emberstack/reflector"
SCRIPT_NAMESPACE="reflector"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Component"        # Component | Resource
SCRIPT_TYPE="tool"              # service | tool | library | database | cache | message-broker
SCRIPT_OWNER="platform-team"    # platform-team | app-team

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="Cross-namespace Secret/ConfigMap mirroring, kept in sync on every change"
SCRIPT_LOGO=""
SCRIPT_WEBSITE="https://github.com/emberstack/kubernetes-reflector"
SCRIPT_TAGS="secrets,cross-namespace,kubernetes"
SCRIPT_SUMMARY="Reflector watches Secrets/ConfigMaps annotated with reflector.v1.k8s.emberstack.com/reflection-allowed and mirrors them into other namespaces, re-syncing automatically on every change (a certificate renewal, a password rotation). Kubernetes volumes cannot cross namespaces on their own - a cert-manager Certificate issued once can still be trusted by a workload in a different namespace once that Secret is reflected into it."
SCRIPT_DOCS="/docs/services/management/reflector"
