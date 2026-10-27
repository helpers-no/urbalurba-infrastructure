#!/bin/bash
# File: scripts/epinio/epinio-expose-route.sh
# Description: Gives one already-pushed Epinio app an external (tunnel-reachable)
#              HostRegexp route, by calling ansible/playbooks/626-epinio-external-route.yml.
#              It is designed to run inside the provision-host container (same convention
#              as scripts/argocd/argocd-register-app.sh) - from the host, invoke it via
#              `./uis exec scripts/epinio/epinio-expose-route.sh` with the env vars below.
#
# Required Parameters:
#   EPINIO_APP_NAME  - the app's name, exactly as given to `epinio push`
#   EPINIO_NAMESPACE - the Epinio org/namespace the app was pushed into
#   EPINIO_APP_PORT  - the port the app listens on
#
# Usage:
#   EPINIO_APP_NAME=your_app \
#   EPINIO_NAMESPACE=your_org \
#   EPINIO_APP_PORT=8080 \
#   ./epinio-expose-route.sh

missing_params=0
if [ -z "$EPINIO_APP_NAME" ]; then
    echo "❌ Error: EPINIO_APP_NAME is not set"
    missing_params=1
fi

if [ -z "$EPINIO_NAMESPACE" ]; then
    echo "❌ Error: EPINIO_NAMESPACE is not set"
    missing_params=1
fi

if [ -z "$EPINIO_APP_PORT" ]; then
    echo "❌ Error: EPINIO_APP_PORT is not set"
    missing_params=1
fi

if [ $missing_params -eq 1 ]; then
    echo ""
    echo "Usage:"
    echo "EPINIO_APP_NAME=your_app \\"
    echo "EPINIO_NAMESPACE=your_org \\"
    echo "EPINIO_APP_PORT=8080 \\"
    echo "./epinio-expose-route.sh"
    exit 1
fi

echo "🔍 Current Parameters:"
echo "EPINIO_APP_NAME: $EPINIO_APP_NAME"
echo "EPINIO_NAMESPACE: $EPINIO_NAMESPACE"
echo "EPINIO_APP_PORT: $EPINIO_APP_PORT"
echo ""

echo "🚀 Exposing $EPINIO_APP_NAME (namespace $EPINIO_NAMESPACE) via Traefik HostRegexp..."

ansible-playbook /mnt/urbalurbadisk/ansible/playbooks/626-epinio-external-route.yml \
  -e "epinio_route_app_name=$EPINIO_APP_NAME" \
  -e "epinio_route_namespace=$EPINIO_NAMESPACE" \
  -e "epinio_route_port=$EPINIO_APP_PORT"

ansible_exit_code=$?
if [ $ansible_exit_code -ne 0 ]; then
    echo "❌ Error: Failed to expose $EPINIO_APP_NAME. Check the output above for details."
    exit 2
fi

echo ""
echo "✅ $EPINIO_APP_NAME is now routed on any hostname matching '$EPINIO_APP_NAME.*'"
echo ""
