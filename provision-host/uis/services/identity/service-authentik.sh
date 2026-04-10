#!/bin/bash
# service-authentik.sh - Authentik service metadata
#
# Authentik provides identity and access management with SSO.

# === Service Metadata (Required) ===
SCRIPT_ID="authentik"
SCRIPT_NAME="Authentik"
SCRIPT_DESCRIPTION="Identity provider and SSO solution"
SCRIPT_CATEGORY="IDENTITY"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="070-setup-authentik.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n authentik -l app.kubernetes.io/name=authentik --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="070-remove-authentik.yml"
SCRIPT_REQUIRES="postgresql redis"
SCRIPT_PRIORITY="40"

# === Deployment Details (Optional) ===
SCRIPT_HELM_CHART="bitnami/authentik"
SCRIPT_NAMESPACE="authentik"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Component"        # Component | Resource
SCRIPT_TYPE="service"          # service | tool | library | database | cache | message-broker
SCRIPT_OWNER="platform-team"   # platform-team | app-team
SCRIPT_PROVIDES_APIS="authentik-api"
SCRIPT_CONSUMES_APIS=""

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="Open-source identity provider with SSO, MFA, and user management"
SCRIPT_LOGO="authentik-logo.svg"
SCRIPT_WEBSITE="https://goauthentik.io"
SCRIPT_TAGS="authentication,sso,identity,oauth,saml,ldap,mfa"
SCRIPT_SUMMARY="Authentik is an open-source Identity Provider focused on flexibility and versatility. It supports SAML, OAuth/OIDC, LDAP, and proxy authentication with built-in MFA support."
SCRIPT_DOCS="/docs/services/identity/authentik"

# === Template Integration (Optional) ===
SCRIPT_CONFIGURABLE="true"
SCRIPT_EXPOSE_PORT="39000"
