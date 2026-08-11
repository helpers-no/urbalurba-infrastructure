#!/bin/bash
# Grafana Alloy - log collection agent.
#
# Ships container logs into Loki. Without it Loki is deployed, healthy and empty:
# it holds only its own canary traffic, and Grafana's Loki datasource returns
# nothing useful.
#
# Deliberately a separate service from Loki: Loki is the store, Alloy is the
# collector, and an installation may reasonably run one without the other.

SCRIPT_ID="alloy"
SCRIPT_NAME="Grafana Alloy"
SCRIPT_DESCRIPTION="Collects container logs and ships them to Loki"
SCRIPT_CATEGORY="OBSERVABILITY"
SCRIPT_PLAYBOOK="031-setup-alloy.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n monitoring -l app.kubernetes.io/name=alloy --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="031-remove-alloy.yml"
SCRIPT_REQUIRES="loki"
SCRIPT_PRIORITY="12"
SCRIPT_HELM_CHART="grafana/alloy"
SCRIPT_NAMESPACE="monitoring"
SCRIPT_KIND="Component"
SCRIPT_TYPE="service"
