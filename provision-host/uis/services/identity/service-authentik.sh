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

# Printed verbatim after `uis undeploy authentik`. `undeploy` deliberately
# keeps the database — UIS cannot back up what it deploys, so a removal that
# destroys data has no undo — and this is how to remove it when you mean to.
#
# 🔴 It lives here, not in 070-remove-authentik.yml, because Ansible's debug
# callback wraps every line it prints and the result cannot be pasted. Two
# releases shipped a remedy that failed byte-for-byte (urb-agents#1732, #1736).
# Keep it pasteable: no continuations, one command per line.
SCRIPT_UNDEPLOY_NOTE="The PostgreSQL database 'authentik' and its role were NOT deleted.

To remove them, run these two lines:

  ./uis shell
  cd /mnt/urbalurbadisk/ansible && ansible-playbook playbooks/utility/u09-authentik-create-postgres.yml -e operation=delete -e confirm=yes

(confirm=yes is required when there is no terminal to answer the prompt -- an agent, a CI job or a script)"
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
# ⚠️ NOT configurable: there is no `lib/configure-authentik.sh` handler, and the
# flag is what `uis configure` reads to decide whether to try. Declaring it
# true advertised a capability that produced "Handler not yet implemented"
# (urb-agents#1710, Terje 2026-09-29). Re-declare it the day a handler lands —
# a unit test now requires the two to agree.
SCRIPT_CONFIGURABLE="false"
SCRIPT_EXPOSE_PORT="39000"
