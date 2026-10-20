#!/bin/bash
# service-cert-manager.sh - cert-manager service metadata
#
# cert-manager issues and renews X.509 certificates in-cluster. UIS has no external CA and no
# cert-manager today (TLS to the outside world ends at the network edge, upstream of the
# cluster) — this is the first in-cluster certificate-issuing capability, backing a self-signed
# ClusterIssuer ("uis-ca") every service can ask for a real certificate from.

# === Service Metadata (Required) ===
SCRIPT_ID="cert-manager"
SCRIPT_NAME="cert-manager"
SCRIPT_DESCRIPTION="X.509 certificate issuance and renewal for Kubernetes"
SCRIPT_CATEGORY="MANAGEMENT"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="025-setup-cert-manager.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n cert-manager -l app.kubernetes.io/component=webhook --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="025-remove-cert-manager.yml"
SCRIPT_REQUIRES=""
SCRIPT_PRIORITY="20"

# === Deployment Details (Optional) ===
SCRIPT_HELM_CHART="jetstack/cert-manager"
SCRIPT_NAMESPACE="cert-manager"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Component"        # Component | Resource
SCRIPT_TYPE="tool"          # service | tool | library | database | cache | message-broker
SCRIPT_OWNER="platform-team"   # platform-team | app-team

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="In-cluster X.509 certificate issuance via a self-signed CA"
SCRIPT_LOGO=""
SCRIPT_WEBSITE="https://cert-manager.io"
SCRIPT_TAGS="tls,certificates,pki,kubernetes"
SCRIPT_SUMMARY="cert-manager automates the issuance and renewal of X.509 certificates inside the cluster. UIS installs it with one self-signed ClusterIssuer (uis-ca) that other services ask for a real certificate, instead of relying on Traefik's ad-hoc per-connection default."
SCRIPT_DOCS="/docs/services/management/cert-manager"
