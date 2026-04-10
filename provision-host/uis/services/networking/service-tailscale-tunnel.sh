#!/bin/bash
# service-tailscale-tunnel.sh - Tailscale tunnel service metadata
#
# Tailscale tunnel provides secure network access via WireGuard VPN.

# === Service Metadata (Required) ===
SCRIPT_ID="tailscale-tunnel"
SCRIPT_NAME="Tailscale Tunnel"
SCRIPT_DESCRIPTION="Secure mesh VPN tunnel"
SCRIPT_CATEGORY="NETWORKING"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="802-deploy-network-tailscale-tunnel.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n tailscale -l app=operator --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="801-remove-network-tailscale-tunnel.yml"
SCRIPT_REQUIRES="nginx"
SCRIPT_PRIORITY="100"

# === Deployment Details (Optional) ===
SCRIPT_HELM_CHART="tailscale/tailscale-operator"
SCRIPT_NAMESPACE="tailscale"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Component"        # Component | Resource
SCRIPT_TYPE="service"          # service | tool | library | database | cache | message-broker
SCRIPT_OWNER="platform-team"   # platform-team | app-team

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="Zero-config WireGuard-based mesh VPN for secure remote access"
SCRIPT_LOGO="tailscale-logo.svg"
SCRIPT_WEBSITE="https://tailscale.com"
SCRIPT_TAGS="vpn,wireguard,mesh-network,remote-access,zero-trust"
SCRIPT_SUMMARY="Tailscale creates a secure, private network between your servers, computers, and cloud instances using WireGuard encryption. It provides zero-config networking with built-in NAT traversal."
SCRIPT_DOCS="/docs/services/networking/tailscale-tunnel"
