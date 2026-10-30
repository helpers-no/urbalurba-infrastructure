#!/bin/bash
# service-github-runner.sh - GitHub Actions self-hosted runner service metadata
#
# In-cluster CI runner registering against GitHub's own protocol (api.github.com), not
# Forgejo's — a separate, incompatible registration API from forgejo-runner
# (urb-agents#1911 flagged this as an open question early on: "one shared runner" turned
# out to mean two separate runner processes, one per protocol, not one process serving
# both). Promoted from ops's own hand-applied, fleet-specific manifest
# (urb-agents#2029/#2030) — that instance pointed at one hardcoded repo
# (terchris/urb-agents) for one purpose (CLI release builds); this is the same proven
# architecture made generic (operator-supplied target repo + PAT), the same way
# forgejo-runner is generic across whichever Forgejo instance it's pointed at.
#
# Needs a Personal Access Token supplied at DEPLOY time only — this playbook mints a
# short-lived (1h) registration token from it via GitHub's own API and stores ONLY that
# in the cluster; the PAT itself is never written to a Secret or any other persisted
# state (urb-agents#2030, ops's own lesson from building the hand-applied version: "no PAT
# needs to live in the cluster long-term if deploy-time minting is acceptable").
#
# No persistence across pod restarts, DELIBERATELY — see 645-setup-github-runner.yml's own
# header for why this is the right tradeoff here, not an oversight.
#
# 🔴 REGISTER/REMOVE/LIST A RUNNER INSTANCE THROUGH THE CLI, NOT `uis deploy` (urb-agents#1928's
# CLI gap, closed for this service): `uis deploy github-runner` has no way to supply a target repo
# or a token, and never did. Use the dedicated subcommand family instead — it mints the token from
# the already-configured GITHUB_ACCESS_TOKEN secret, same convention `uis argocd register` uses:
#   uis github-runner register <instance> <owner/repo>   # a new, independent instance
#   uis github-runner remove <instance>                  # remove just that one
#   uis github-runner list                                # every instance + the repo it serves
#
# 🔴 MULTIPLE INSTANCES CAN COEXIST ON ONE CLUSTER, ONE PER TARGET REPO (urb-agents#2053) — each
# `register` call adds a second, fully independent runner alongside any already running, without
# touching it (see 645-setup-github-runner.yml's own header for the full story and the collision
# safety check; `--force` on `register` to deliberately retarget an existing instance). Known
# limitation, not fixed here: SCRIPT_CHECK_COMMAND below and `uis status` only ever report "is ANY
# instance healthy", not a specific one — `uis github-runner list` is the per-instance view.
#
# The ORIGINAL/default (unnamed) instance predates all of this and is not managed through the new
# subcommands — it still comes up via the direct ansible-playbook invocation with no
# `github_runner_instance` set (see 645-setup-github-runner.yml's own header).

# === Service Metadata (Required) ===
SCRIPT_ID="github-runner"
SCRIPT_NAME="GitHub Runner"
SCRIPT_DESCRIPTION="In-cluster GitHub Actions self-hosted runner (CI for GitHub-hosted repos)"
SCRIPT_CATEGORY="MANAGEMENT"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="645-setup-github-runner.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n github-runner -l app=github-runner --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="645-remove-github-runner.yml"
SCRIPT_REQUIRES=""
SCRIPT_PRIORITY="82"

# === Deployment Details (Optional) ===
SCRIPT_NAMESPACE="github-runner"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Component"        # Component | Resource
SCRIPT_TYPE="tool"             # service | tool | library | database | cache | message-broker
SCRIPT_OWNER="platform-team"   # platform-team | app-team

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="CI runner for GitHub Actions workflows, in-cluster"
SCRIPT_LOGO=""
SCRIPT_WEBSITE="https://docs.github.com/en/actions/hosting-your-own-runners"
SCRIPT_TAGS="ci,actions,runner,github"
SCRIPT_SUMMARY="Registers a GitHub Actions self-hosted runner against an operator-supplied repository, executing workflow jobs via a private docker:dind sidecar — the same proven architecture as forgejo-runner, for GitHub's own (incompatible) runner protocol instead of Forgejo's. The SAME Deployment runs identically on Rancher Desktop and on a Proxmox k3s cluster."
SCRIPT_DOCS="/docs/services/management/github-runner"
