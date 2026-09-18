#!/bin/bash
# service-oauth2-proxy.sh - oauth2-proxy service metadata
#
# A login gate that borrows someone else's user directory. UIS stores no users,
# no passwords and no groups — it keeps a list of who is allowed in.
#
# WHY THIS EXISTS ALONGSIDE AUTHENTIK. Authentik is an identity provider: most of
# its weight — PostgreSQL, Redis, a worker, blueprints, backups, upgrades —
# exists to store and administer users. When the people who should get in already
# have accounts at GitHub, Google or a corporate IdP, that weight buys nothing.
# This is the other shape: delegate identity outward, keep a list.
#
#   we own the users                       -> authentik
#   someone else owns them, we keep a list -> oauth2-proxy
#   users must pick between providers      -> authentik (oauth2-proxy supports
#                                             one provider per instance)
#
# See website/docs/services/identity/oauth2-proxy.md and
# plans/backlog/PLAN-service-oauth2-proxy.md.

# === Service Metadata (Required) ===
SCRIPT_ID="oauth2-proxy"
SCRIPT_NAME="oauth2-proxy"
SCRIPT_DESCRIPTION="Login gate using an external identity provider"
SCRIPT_CATEGORY="IDENTITY"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="072-setup-oauth2-proxy.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n oauth2-proxy -l app=oauth2-proxy --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="072-remove-oauth2-proxy.yml"

# 🔴 DELIBERATELY EMPTY, AND THIS IS THE POINT OF THE SERVICE.
# service-authentik.sh declares SCRIPT_REQUIRES="postgresql redis". This one
# requires nothing: no database, no cache, no persistent state, nothing to back
# up or migrate. If a future change adds a dependency here, the reason for
# choosing this component over Authentik has gone — reconsider rather than add.
SCRIPT_REQUIRES=""

# Before authentik's 40. Nothing depends on this service; it is deployed early so
# a protected route never exists before the gate that fronts it.
SCRIPT_PRIORITY="35"

# === Deployment Details (Optional) ===
SCRIPT_HELM_CHART=""
SCRIPT_NAMESPACE="oauth2-proxy"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Component"
SCRIPT_TYPE="service"
SCRIPT_OWNER="platform-team"
SCRIPT_PROVIDES_APIS=""
SCRIPT_CONSUMES_APIS=""

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="Authentication gate that delegates identity to an external provider"
SCRIPT_LOGO=""
SCRIPT_WEBSITE="https://oauth2-proxy.github.io/oauth2-proxy/"
SCRIPT_TAGS="authentication,oauth,oidc,sso,gate,forward-auth"
SCRIPT_SUMMARY="oauth2-proxy authenticates visitors against an external identity provider (GitHub, Google, or any OIDC issuer) and allows through only the people on a configured list. It runs as a Traefik ForwardAuth gate, holds no user records and no persistent state, so it fits the case where the user directory belongs to someone else. It provides authentication only — everyone admitted is equal, with no groups or per-service permissions."
SCRIPT_DOCS="/docs/services/identity/oauth2-proxy"

# === Template Integration (Optional) ===
SCRIPT_CONFIGURABLE="false"
SCRIPT_EXPOSE_PORT=""
