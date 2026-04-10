#!/bin/bash
# service-cloudflare-tunnel.sh - Cloudflare tunnel service metadata
#
# Cloudflare Tunnel provides secure access to services without exposing ports.

# === Service Metadata (Required) ===
SCRIPT_ID="cloudflare-tunnel"
SCRIPT_NAME="Cloudflare Tunnel"
SCRIPT_DESCRIPTION="Secure tunnel to Cloudflare network"
SCRIPT_CATEGORY="NETWORKING"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="820-deploy-network-cloudflare-tunnel.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n default -l app=cloudflared --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="821-remove-network-cloudflare-tunnel.yml"
SCRIPT_REQUIRES="nginx"
SCRIPT_PRIORITY="101"

# === Deployment Details (Optional) ===
SCRIPT_IMAGE="cloudflare/cloudflared:latest"
SCRIPT_NAMESPACE="default"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Component"        # Component | Resource
SCRIPT_TYPE="service"          # service | tool | library | database | cache | message-broker
SCRIPT_OWNER="platform-team"   # platform-team | app-team

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="Secure outbound-only tunnel to expose services via Cloudflare"
SCRIPT_LOGO="cloudflare-logo.svg"
SCRIPT_WEBSITE="https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/"
SCRIPT_TAGS="tunnel,cloudflare,cdn,ddos-protection,reverse-proxy"
SCRIPT_SUMMARY="Cloudflare Tunnel creates a secure, outbound-only connection between your origin and Cloudflare's edge. No need to open public inbound ports - traffic is routed through Cloudflare's network."
SCRIPT_DOCS="/docs/services/networking/cloudflare-tunnel"
