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
# Runs via GitHub's own Actions Runner Controller (ARC, the `gha-runner-scale-set` Helm
# chart) as of `urb-agents#2073`/`#2075` — Terje's direction, after live bifrost OOM/
# eviction debugging (`#2067`/`#2071`/`#2072`) showed a static, always-on Deployment
# architecturally cannot scale to zero. Full rationale in
# `PLAN-service-github-runner-arc-migration.md`.
#
# 🔴 THE PAT NOW PERSISTS IN THE CLUSTER, UNLIKE THIS SERVICE'S ORIGINAL DESIGN. The old
# design deliberately discarded the PAT after minting one short-lived token
# (urb-agents#2030's "no PAT needs to live in the cluster long-term" finding). ARC cannot
# work that way — its listener needs to keep minting its own short-lived runner tokens
# with no human in the loop, for as long as an instance exists, so the PAT is stored as a
# persistent Secret (`<resource-name>-token`, key `github_token`). Same narrow
# 'Administration' repository permission as before; only its lifetime changed. A real
# upside from the same change: there is no more "pod restart needs a fresh `register` run"
# limitation — ephemeral runners get a fresh token automatically, every time, with no human
# step.
#
# 🔴 REGISTER/REMOVE/LIST A RUNNER INSTANCE THROUGH THE CLI, NOT `uis deploy` (urb-agents#1928's
# CLI gap, closed for this service): `uis deploy github-runner` has no way to supply a target repo
# or a token, and never did. Use the dedicated subcommand family instead — it reads the PAT from
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
# instance's listener up", not a specific one — `uis github-runner list` is the per-instance view.
#
# 🔵 SCALE-TO-ZERO MEANS "NO RUNNING PODS" IS THE NORMAL IDLE STATE, NOT A FAULT —
# SCRIPT_CHECK_COMMAND below checks for the shared ARC controller's listener(s), not an
# ephemeral runner pod (which only exists while a job is actually in progress, by design).
#
# The ORIGINAL/default (unnamed) instance moved to this same ARC-backed mechanism too — there is
# no separate legacy path left to maintain (see `PLAN-service-github-runner-arc-migration.md`'s
# own Rollout section for how an already-running pre-ARC instance migrates).

# === Service Metadata (Required) ===
SCRIPT_ID="github-runner"
SCRIPT_NAME="GitHub Runner"
SCRIPT_DESCRIPTION="In-cluster GitHub Actions self-hosted runner (CI for GitHub-hosted repos)"
SCRIPT_CATEGORY="MANAGEMENT"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="645-setup-github-runner.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n github-runner --no-headers 2>/dev/null | grep listener | grep -q Running"
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
SCRIPT_SUMMARY="Registers a GitHub Actions self-hosted runner (via Actions Runner Controller) against an operator-supplied repository, scaling to zero between jobs and executing each one via a private docker:dind sidecar. The SAME chart install runs identically on Rancher Desktop and on a Proxmox k3s cluster."
SCRIPT_DOCS="/docs/services/management/github-runner"
