#!/bin/bash
# service-forgejo-runner.sh - Forgejo Actions runner service metadata
#
# In-cluster CI runner for Forgejo Actions — ONE implementation (this Deployment, the
# DinD sidecar, the register flow) for every k3s cluster it applies to, Rancher Desktop
# or one of this lab's own Proxmox k3s clusters (urb-agents#1982: "k3s is k3s," same
# reasoning bao+ESO already use). Supersedes the earlier framing of this as purely the
# "Rancher Desktop counterpart" to a dedicated Proxmox VM runner — that VM-based lab extra
# was this pod-based version's predecessor, retired outright (urb-agents#1997) once this
# was live-verified; see platforms/proxmox/STRUCTURE.md's "nas's history in this platform"
# note for the full timeline.
#
# 🔵 THE ONE REAL PLATFORM DIFFERENCE: whether Forgejo itself is in-cluster or external.
# 640-setup-forgejo-runner.yml's own `forgejo_external_url` var switches modes — see that
# file's own header. `platforms/proxmox/scripts/forgejo-runner-pod-deploy.sh` is the thin
# wrapper that resolves the Proxmox forgejo CORE_SERVICES guest's own address and supplies
# it, the same documented workaround the CLI-gap note below already uses.
#
# Needs a registration token minted by hand after a Forgejo admin account exists — same
# "never defaulted" rule the Proxmox runner role enforces.
#
# 🔴 FOUND LIVE BY imac (urb-agents#1928): `uis deploy <service> -- -e key=value` does
# NOT exist — `cmd_deploy()` in uis-cli.sh only parses `--app`/`--url-prefix` and
# rejects anything else as "Unknown option". There is no extra-vars passthrough on
# `uis deploy` at all (filed separately as a real CLI gap, not fixed here — worth
# either adding real passthrough or making an unrecognized flag refuse loudly instead
# of silently falling through to "no args", which deploys every enabled service).
# Until that lands, run the playbook directly:
#   ansible-playbook playbooks/640-setup-forgejo-runner.yml \
#     -e target_host="rancher-desktop" -e forgejo_runner_token="..."
# (same form 640-setup-forgejo-runner.yml's own usage comment already documents —
# that one was always correct; this file's own comment was the one that was wrong.)

# === Service Metadata (Required) ===
SCRIPT_ID="forgejo-runner"
SCRIPT_NAME="Forgejo Runner"
SCRIPT_DESCRIPTION="In-cluster Forgejo Actions runner (CI for Forgejo-hosted repos)"
SCRIPT_CATEGORY="MANAGEMENT"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="640-setup-forgejo-runner.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n forgejo-runner -l app=forgejo-runner --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="640-remove-forgejo-runner.yml"
SCRIPT_REQUIRES="forgejo"
SCRIPT_PRIORITY="81"

# === Deployment Details (Optional) ===
SCRIPT_NAMESPACE="forgejo-runner"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Component"        # Component | Resource
SCRIPT_TYPE="tool"             # service | tool | library | database | cache | message-broker
SCRIPT_OWNER="platform-team"   # platform-team | app-team

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="CI runner for Forgejo Actions workflows, in-cluster"
SCRIPT_LOGO=""
SCRIPT_WEBSITE="https://forgejo.org/docs/latest/admin/actions/"
SCRIPT_TAGS="ci,actions,runner,forgejo"
SCRIPT_SUMMARY="Registers a Forgejo Actions runner against this install's own Forgejo (uis deploy forgejo), executing workflow jobs via a private docker:dind sidecar. The SAME Deployment runs identically on Rancher Desktop and on a Proxmox k3s cluster — only whether Forgejo is in-cluster or an external LXC guest differs, via the forgejo_external_url setup var."
SCRIPT_DOCS="/docs/services/management/forgejo-runner"
