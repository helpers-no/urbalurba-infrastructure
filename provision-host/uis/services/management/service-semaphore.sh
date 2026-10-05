#!/bin/bash
# service-semaphore.sh - SemaphoreUI service metadata
#
# METADATA ONLY. No logic. The playbook does the work.
#
# SemaphoreUI is a web UI and API for running Ansible, Terraform, OpenTofu
# and PowerShell. Ships with zero projects, repositories, inventories,
# templates or access keys configured - an operator wires their own
# automation in afterwards. See
# website/docs/ai-developer/plans/completed/INVESTIGATE-service-semaphore.md.

# === Service Metadata (Required) ===
SCRIPT_ID="semaphore"
SCRIPT_NAME="SemaphoreUI"
SCRIPT_DESCRIPTION="Web UI and API for running Ansible, Terraform, OpenTofu and PowerShell"
SCRIPT_CATEGORY="MANAGEMENT"

# === Deployment (Required) ===
SCRIPT_PLAYBOOK="630-setup-semaphore.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n semaphore -l app=semaphore --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="630-remove-semaphore.yml"
SCRIPT_REQUIRES=""
SCRIPT_PRIORITY="85"

# === Deployment Details (Optional) ===
SCRIPT_IMAGE="semaphoreui/semaphore:v2.19.12"
SCRIPT_HELM_CHART=""
SCRIPT_NAMESPACE="semaphore"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Component"        # Component | Resource
SCRIPT_TYPE="tool"             # service | tool | library | database | cache | message-broker
SCRIPT_OWNER="platform-team"   # platform-team | app-team
SCRIPT_PROVIDES_APIS="semaphore-api"
SCRIPT_CONSUMES_APIS=""

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="Web UI and API for running Ansible, Terraform, OpenTofu and PowerShell against your own hosts"
SCRIPT_LOGO="semaphore-logo.svg"
SCRIPT_WEBSITE="https://semaphoreui.com"
SCRIPT_TAGS="automation,ansible,terraform,opentofu,ci-cd,playbooks,ops"
SCRIPT_SUMMARY="SemaphoreUI gives Ansible, Terraform, OpenTofu and PowerShell playbooks a web UI, an API and a non-interactive CLI, instead of a terminal and a cron job. A project owns everything a run needs - the git repository, the inventory, the stored access keys - and SemaphoreUI executes templates against it, in-cluster, with a real history of every task it ran. A clean install ships with none of that configured: zero projects, repositories or access keys, the same empty-by-default convention as dagster-code-locations.yaml. Running inside the cluster is not a limitation - anything the automation reaches over SSH or HTTP (a VM to patch, a watchdog to notify) it reaches identically from a pod; the one thing no in-cluster tool can do is recover the specific cluster its own pod depends on. Note for anyone piping secrets through it: issued API tokens are stored as the bearer value itself, not a hash - a deliberate design choice made upstream, not a UIS defect."
SCRIPT_DOCS="/docs/services/management/semaphore"
