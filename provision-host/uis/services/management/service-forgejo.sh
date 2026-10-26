#!/bin/bash
# service-forgejo.sh - Forgejo service metadata
#
# Self-hosted git host + its own built-in OCI registry, as an in-cluster `uis deploy
# forgejo` service — the Rancher Desktop (dev/test) counterpart to the Proxmox LXC guest
# in platforms/proxmox/ansible/roles/forgejo/. Same proven settings translated to
# Kubernetes, not independently designed — see
# website/docs/ai-developer/plans/completed/PLAN-system-forgejo-rancher-desktop.md.
#
# Scope: git host + registry only. No admin account (explicit operator step, same as the
# Proxmox guest). No git-ssh (HTTP clone + the registry only, this phase). The Actions
# runner is a separate service, `uis deploy forgejo-runner` (SCRIPT_REQUIRES this one).

# === Service Metadata (Required) ===
SCRIPT_ID="forgejo"
SCRIPT_NAME="Forgejo"
SCRIPT_DESCRIPTION="Self-hosted git host + its own built-in OCI registry"
SCRIPT_CATEGORY="MANAGEMENT"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="635-setup-forgejo.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n forgejo -l app=forgejo --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="635-remove-forgejo.yml"
SCRIPT_REQUIRES=""
SCRIPT_PRIORITY="80"

# === Deployment Details (Optional) ===
SCRIPT_NAMESPACE="forgejo"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Component"        # Component | Resource
SCRIPT_TYPE="service"          # service | tool | library | database | cache | message-broker
SCRIPT_OWNER="platform-team"   # platform-team | app-team

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="Self-hosted git host and OCI registry for UIS's own CI"
SCRIPT_LOGO=""
SCRIPT_WEBSITE="https://forgejo.org"
SCRIPT_TAGS="git,ci,registry,self-hosted"
SCRIPT_SUMMARY="Forgejo is a self-hosted git host with its own built-in OCI registry — the git host and image store Forgejo Actions (uis deploy forgejo-runner) pushes to and pulls from. The in-cluster counterpart of the dedicated Proxmox guest built for production."
SCRIPT_DOCS="/docs/services/management/forgejo"
