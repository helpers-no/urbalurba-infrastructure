#!/bin/bash
# service-postgrest.sh - PostgREST service metadata
#
# PostgREST turns a curated PostgreSQL schema into a REST API. UIS
# deploys one PostgREST instance per consuming application; all
# instances share a namespace and the platform's PostgreSQL service.
#
# Multi-instance lifecycle:
#   ./uis configure postgrest --app <name> [--database <db>] \
#       [--schemas api_v1,marts,raw] [--url-prefix api-<name>]
#   ./uis deploy postgrest --app <name>
#
# The schema list lives on the per-app secret (key PGRST_DB_SCHEMAS),
# written by configure and read by the Deployment template via
# valueFrom.secretKeyRef. Deploy does not accept --schemas — there's only
# one source of truth.
#
# See INVESTIGATE-postgrest.md and PLAN-002-postgrest-deployment.md.

# === Service Metadata (Required) ===
SCRIPT_ID="postgrest"
SCRIPT_NAME="PostgREST"
SCRIPT_DESCRIPTION="Auto-generated REST API from a curated PostgreSQL schema"
SCRIPT_CATEGORY="INTEGRATION"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="088-setup-postgrest.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get deploy -n postgrest -l app.kubernetes.io/name=postgrest --no-headers 2>/dev/null | grep -qE '\\s([1-9][0-9]*)/\\1\\s'"
SCRIPT_REMOVE_PLAYBOOK="088-remove-postgrest.yml"
SCRIPT_REQUIRES="postgresql"
SCRIPT_MULTI_INSTANCE="true"
SCRIPT_CONFIGURABLE="true"
SCRIPT_PRIORITY="50"

# === Deployment Details (Optional) ===
# Image pinned to latest stable 2026-04-29 per INVESTIGATE-system-version-pinning.md.
# v14.x still emits Swagger 2.0 (a.k.a. OpenAPI 2.0) at GET /; v15+ may switch
# to OpenAPI 3.x. PostgREST follows MAJOR.PATCH versioning; only even majors
# are released. Upgrade by bumping this tag and re-running Phase 6 validation.
SCRIPT_IMAGE="postgrest/postgrest:v14.10"
SCRIPT_NAMESPACE="postgrest"

# === How a POD addresses this service ===
# 🔵 An application declares `env_from_services: VAR: postgrest` and UIS composes
# <scheme>://<name>.<SCRIPT_NAMESPACE>.svc.cluster.local:<port> from these.
#
# 🔴 THE TENANT MUST NEVER WRITE THAT ADDRESS ITSELF. The namespace and the
# service name belong to UIS and change between releases - gravitee moved from
# `default` to `gravitee` in 2d0570d - so an artifact holding the literal would
# break silently that day, in a different repository, with no signal here.
# Keeping the parts here means a move is one edit and every artifact follows.
#
# ⚠️ `{app}` expands to the installing definition's params.app_name: UIS deploys
# one PostgREST per consuming application.
#
# ⚠️ THE PORT IS THE PRIMARY PUBLISHED ONE, NOT AN INFERENCE. The Service in
# templates/088-postgrest-config.yml.j2 publishes TWO: `api` 3000 and `admin`
# 3001. Anything that guesses a single port guesses wrong half the time.
SCRIPT_IN_CLUSTER_SCHEME="http"
SCRIPT_IN_CLUSTER_NAME="{app}-postgrest"
SCRIPT_IN_CLUSTER_PORT="3000"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Component"
SCRIPT_TYPE="service"
SCRIPT_OWNER="platform-team"
# Multi-instance — see INVESTIGATE-postgrest.md Decisions #3, #16, #19
# Backstage shape per Decision #9 (deferred until Backstage deploys)
SCRIPT_CONSUMES_APIS="postgresql"
SCRIPT_PROVIDES_APIS=""  # TODO(backstage): emit per-instance <app>-rest entries when Backstage deploys

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="A platform service that turns a curated api_v1 PostgreSQL schema into a public REST API."
SCRIPT_SUMMARY="PostgREST is a single Haskell binary that introspects a PostgreSQL schema and exposes its tables and views as REST endpoints, with foreign keys becoming embedded-resource relations and OpenAPI metadata served at GET /. PostgREST 12.x emits Swagger 2.0; later releases may upgrade to OpenAPI 3.x. UIS deploys one PostgREST instance per consuming application, all sharing a single namespace and the shared PostgreSQL service. Each instance is configured separately via ./uis configure postgrest --app <name>."
SCRIPT_LOGO="postgrest-logo.svg"
SCRIPT_WEBSITE="https://postgrest.org"
SCRIPT_TAGS="rest-api,postgrest,api-platform,postgresql,read-only"
SCRIPT_DOCS="/docs/services/integration/postgrest"
