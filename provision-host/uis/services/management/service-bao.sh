#!/bin/bash
# service-bao.sh - OpenBao service metadata
#
# OpenBao holds this platform's secrets in production (platforms/proxmox/ansible/roles/bao,
# built and proven against real hardware) but, until now, had neither a UIS service definition
# nor an in-cluster dev form - named explicitly in adding-a-service.md's list of current
# Principle 0 violators. See
# website/docs/ai-developer/plans/backlog/INVESTIGATE-service-openbao.md for the investigation
# behind this.
#
# Dev gets a REAL OpenBao (raft storage, static seal, `kubernetes` auth - the same mechanisms
# production uses), not a fake backend standing in for the interface. TLS and audit logging are
# the two deliberate dev-only simplifications - see manifests/027-bao-config.yaml's own header.
#
# Requires external-secrets: the `kubernetes` auth method this role configures is consumed by
# ESO's own ClusterSecretStore, which this service also creates - ESO's CRDs must exist first.

# === Service Metadata (Required) ===
SCRIPT_ID="bao"
SCRIPT_NAME="OpenBao"
SCRIPT_DESCRIPTION="Secrets management (KV v2 + kubernetes auth), exposed to the cluster via a ClusterSecretStore"
SCRIPT_CATEGORY="MANAGEMENT"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="027-setup-bao.yml"
SCRIPT_MANIFEST=""
# 🔴 LABEL SELECTOR, NOT A HARDCODED POD NAME — urb-agents#1956, live-confirmed: the openbao Helm
# chart names its StatefulSet/pod "bao-openbao-0", not "bao-0", for a release named "bao". A
# literal name broke an earlier draft of this check outright (always exit 1, pod never existed by
# that name) and made bao silently absent from `uis status` rather than reported unhealthy. Same
# shape every other service's own check uses (garage, cert-manager, ...) - a label survives a
# future chart naming change the way a literal pod name already proved it cannot. This script is
# also `source`d directly elsewhere, so the value must stay a plain string with no $(...) inside
# it - that would eagerly run at source time instead of staying a live check.
SCRIPT_CHECK_COMMAND="kubectl get pods -n bao -l app.kubernetes.io/instance=bao --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="027-remove-bao.yml"
SCRIPT_REQUIRES="external-secrets"
SCRIPT_PRIORITY="22"

# === Deployment Details (Optional) ===
SCRIPT_HELM_CHART="openbao/openbao"
SCRIPT_NAMESPACE="bao"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Resource"          # Component | Resource
SCRIPT_TYPE="service"           # service | tool | library | database | cache | message-broker
SCRIPT_OWNER="platform-team"    # platform-team | app-team

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="Secrets management with KV v2 storage and Kubernetes-native auth"
SCRIPT_LOGO=""
SCRIPT_WEBSITE="https://openbao.org"
SCRIPT_TAGS="secrets,vault,openbao,kubernetes-auth"
SCRIPT_SUMMARY="OpenBao deployed in-cluster: raft storage, a static (auto-unseal) seal generated fresh per install, a KV v2 mount named 'platform', and the kubernetes auth method configured for External Secrets Operator. Exposes a ClusterSecretStore named 'openbao' so an ExternalSecret a developer writes here resolves identically wherever that store exists - the same interface production's own OpenBao (platforms/proxmox) answers. Requires external-secrets."
SCRIPT_DOCS="/docs/services/management/bao"
