#!/bin/bash
# service-forgejo-runner.sh - Forgejo Actions runner service metadata
#
# In-cluster CI runner for Forgejo Actions — the Rancher Desktop (dev/test) counterpart
# to the dedicated Proxmox VM runner (platforms/proxmox, ops's own proven IaC). Same
# runner image/version and registration flow reused, not independently invented;
# execution mechanism differs (a private docker:dind sidecar here, a real host Docker
# socket there) because this target has no spare dedicated host to mount one from — see
# website/docs/ai-developer/plans/backlog/PLAN-system-forgejo-rancher-desktop.md.
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
SCRIPT_SUMMARY="Registers a Forgejo Actions runner against this install's own Forgejo (uis deploy forgejo), executing workflow jobs via a private docker:dind sidecar. The in-cluster counterpart of the dedicated Proxmox VM runner built for production — same runner version and registration flow, different job-isolation mechanism because this target has no spare dedicated host."
SCRIPT_DOCS="/docs/services/management/forgejo-runner"
