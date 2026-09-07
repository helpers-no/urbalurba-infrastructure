# Plan: PostgREST deployment (platform service implementation)

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed (2026-04-29)

**Goal**: Implement PostgREST as a deployable, multi-instance UIS service following every decision recorded in [INVESTIGATE-postgrest.md](./INVESTIGATE-postgrest.md). After this plan, `./uis configure postgrest --app <name>` followed by `./uis deploy postgrest --app <name>` produces a working REST API serving an `api_v1` schema, and the platform supports the multi-instance pattern as a reusable convention.

**Last Updated**: 2026-04-29 — all 6 phases shipped; end-to-end Phase 6 validation passed against rancher-desktop. Two bugs surfaced during validation and fixed: create-path silent SQL failure (`2640d98`) and purge-path silent role-drop failure (`98627ab`). PLAN-002 also corrected the docs claim about OpenAPI 3.0 — PostgREST 12.x and 14.x both emit Swagger 2.0 / OpenAPI 2.0 at `GET /`. Image pin bumped to `v14.10` in `b6e34f8` (PR #133); the smoke checks in this plan use `jq .swagger` accordingly.

**Investigation**: [INVESTIGATE-postgrest.md](./INVESTIGATE-postgrest.md) — 23 resolved decisions; no open design questions.

**Prerequisites**:
- [PLAN-001-postgrest-documentation.md](../completed/PLAN-001-postgrest-documentation.md) approved by the Atlas developer. The docs are the design contract this plan builds toward; if PLAN-001 surfaces a design gap (case (c) feedback), update the investigate and revise this plan before starting.
- The metadata file `provision-host/uis/services/integration/service-postgrest.sh`, the docs page `website/docs/services/integration/postgrest.md`, and the logo already exist (delivered by PLAN-001). This plan extends them; it does not recreate them.

**Blocks**:
- PLAN-003-postgrest-verify.md (verification playbook depends on a deployable service)
- PLAN-004-postgrest-jwt-auth.md (auth layer depends on a working anonymous-only deployment)
- PLAN-005-multi-instance-formatters.md (formatter polish — non-blocking, can run after this)

---

## Overview

PostgREST is the first UIS multi-instance service. Most of this plan is PostgREST-specific implementation, but **two pieces are platform infrastructure** that other multi-instance services will reuse:

1. The `multiInstance: true` metadata flag and the way `configure.sh` and `uis-cli.sh` interpret it (Decision #23).
2. The `ansible/playbooks/templates/` convention for per-instance Jinja-rendered manifests (Decision #21).

Both are introduced here as PostgREST's deployment requires them. They become the precedent for future multi-instance services.

The plan is structured so each phase produces something observable and reviewable on its own. Phase order respects dependencies: platform plumbing first, handler next, then templates and playbooks, then CLI dispatch, then docs.

---

## Phase 1: Platform metadata — `multiInstance` flag

The flag is the single piece of metadata that distinguishes PostgREST's lifecycle from existing single-instance services. Phase 1 wires it through metadata only — no behavior change yet.

### Tasks

- [ ] 1.1 Add `SCRIPT_MULTI_INSTANCE="true"` to `provision-host/uis/services/integration/service-postgrest.sh`. Place it next to `SCRIPT_REQUIRES`.
- [ ] 1.2 Extend `provision-host/uis/lib/service-scanner.sh` to read `SCRIPT_MULTI_INSTANCE` and emit `"multiInstance": true|false` in the service entry of `services.json`. Default to `false` when absent — backwards-compatible with every existing service.
- [ ] 1.3 Regenerate `services.json` via the established docs/services pipeline. Verify the postgrest entry contains `"multiInstance": true` and no other service entry changed.

### Validation

```bash
./uis docs generate
jq '.services[] | select(.id == "postgrest") | {id, multiInstance}' \
  website/src/data/services.json
# Expect: {"id": "postgrest", "multiInstance": true}

jq '.services[] | select(.multiInstance == true) | .id' \
  website/src/data/services.json
# Expect: "postgrest" (and only postgrest)
```

User confirms `services.json` is valid and unchanged for non-postgrest services.

---

## Phase 2: Configure handler + `configure.sh` precheck routing

This phase resolves the `_is_service_deployed` precheck conflict (gap #1, closed by Decision #23) and lands the `configure-postgrest.sh` handler that creates Postgres roles and writes the per-app secret.

### Tasks

- [ ] 2.1 Modify `provision-host/uis/lib/configure.sh:65-189` (`run_configure`) to accept two new flags: `--schema <name>` (default `api_v1`) and `--url-prefix <name>` (default `api-${app}`). Existing flags (`--app`, `--database`, `--init-file`, `--namespace`, `--secret-name-prefix`, `--json`) keep their current behavior for other services.
- [ ] 2.2 Modify `configure.sh:165` precheck logic per Decision #23. Pseudocode:
  ```bash
  if _is_multi_instance "$service_id"; then
      for dep in $(_get_requires "$service_id"); do
          if ! _is_service_deployed "$dep"; then
              _configure_error "deploy_check" "$service_id" \
                  "Cannot configure $service_id: dependency '$dep' is not deployed. Deploy it first: ./uis deploy $dep"
          fi
      done
  else
      if ! _is_service_deployed "$service_id"; then
          _configure_error "deploy_check" "$service_id" \
              "Service '$service_id' is not deployed. Deploy it first: ./uis deploy $service_id"
      fi
  fi
  ```
  Add helper functions `_is_multi_instance` and `_get_requires` reading from `services.json`.
- [ ] 2.3 Add `postgrest` to the list in the `_is_configurable` error message at `configure.sh:159` so the helpful "Configurable services: …" line stays accurate.
- [ ] 2.4 Create `provision-host/uis/lib/configure-postgrest.sh` (no `handlers/` subdirectory — matches existing `configure-postgresql.sh`). Mirror that file's structure:
  - `_pgrst_get_admin_password`, `_pgrst_get_pod`, `_pgrst_exec_*` helpers reuse the same kubeconfig path and pod-discovery pattern as `configure-postgresql.sh:18-67`.
  - `configure_service` (the entrypoint) accepts `service_id`, `app_name`, `database_name`, `init_file`, `json_output`, `namespace`, `secret_name_prefix`, plus the new `schema` and `url_prefix` arguments threaded from `run_configure`.
  - **Reject `--namespace` and `--secret-name-prefix` (Decision #6).** If either is non-empty, error with the message recorded in Decision #6 and exit non-zero. Tests for the rejection path are in Phase 6 validation.
  - Idempotent path: if both `<app>_authenticator` and `<app>_web_anon` roles exist AND the secret `<app>-postgrest` exists in namespace `postgrest`, return success as no-op (Decision #17). Do not regenerate the password.
  - Create path: generate password (same pattern as `configure-postgresql.sh:233`), run the SQL block:
    ```sql
    CREATE ROLE <app>_web_anon NOLOGIN;
    CREATE ROLE <app>_authenticator LOGIN PASSWORD '<pw>' NOINHERIT;
    GRANT <app>_web_anon TO <app>_authenticator;
    GRANT USAGE ON SCHEMA <schema> TO <app>_web_anon;
    GRANT SELECT ON ALL TABLES IN SCHEMA <schema> TO <app>_web_anon;
    ALTER DEFAULT PRIVILEGES IN SCHEMA <schema> GRANT SELECT ON TABLES TO <app>_web_anon;
    ```
    The final `ALTER DEFAULT PRIVILEGES` line is **load-bearing** — without it, views added to `<schema>` after configure runs are silently invisible to anonymous requests (they appear in PostgREST's OpenAPI but return `401`/empty rows because `<app>_web_anon` has no `SELECT`). See [INVESTIGATE-postgrest.md](./INVESTIGATE-postgrest.md) addendum (2026-04-29) for the failure mode Atlas reproduced and the rationale for fixing here rather than per-consumer.
  - Ensure namespace `postgrest` exists (reuse `_pg_ensure_namespace` pattern from `configure-postgresql.sh:105-112`).
  - Create secret `<app>-postgrest` in namespace `postgrest`, key `PGRST_DB_URI`, value `postgresql://<app>_authenticator:<pw>@postgresql.default.svc.cluster.local:5432/<database>`.
  - JSON output schema per Decision #20: `{app, namespace, secret, in_cluster_url, public_url_prefix}` — no credentials. Plain output: a single "next step" hint pointing at `./uis deploy postgrest --app <app>`.
- [ ] 2.5 Add `--rotate` flag handling: when set, regenerate the `<app>_authenticator` password, run `ALTER USER`, and overwrite the secret. Error if the role does not already exist (cannot rotate what does not exist).
- [ ] 2.6 Add `--purge` flag handling for use with `./uis configure postgrest --app <name> --purge`: drops both Postgres roles and removes the secret. Errors if a Deployment for the app still exists in the `postgrest` namespace (require `./uis undeploy postgrest --app <name>` first per Decision #18).

### Validation

Against a running cluster with postgresql deployed:

```bash
# Happy path
./uis configure postgrest --app testapp --database testapp_db --schema api_v1 --url-prefix api-testapp --json
kubectl get secret testapp-postgrest -n postgrest -o jsonpath='{.data.PGRST_DB_URI}' | base64 -d

# Idempotency: second call is a no-op
./uis configure postgrest --app testapp --database testapp_db --schema api_v1 --url-prefix api-testapp --json
# Expect status: "already_configured" or no-op marker

# Rejected flags
./uis configure postgrest --app testapp --namespace foo
# Expect: error with the message from Decision #6

# Precheck on missing dependency
kubectl scale deployment postgresql -n default --replicas=0
./uis configure postgrest --app testapp2
# Expect: "Cannot configure postgrest: dependency 'postgresql' is not deployed."
kubectl scale deployment postgresql -n default --replicas=1

# Cleanup
./uis configure postgrest --app testapp --purge
psql -c "SELECT 1 FROM pg_roles WHERE rolname='testapp_authenticator'"
# Expect: empty result
```

User confirms each command behaves as expected.

---

## Phase 3: Manifest templates and playbooks

This phase establishes the `ansible/playbooks/templates/` convention (Decision #21 — new pattern, not a follow-pattern). PostgREST is the first user.

### Tasks

- [ ] 3.1 Create directory `ansible/playbooks/templates/`. Add a short README.md inside explaining: the directory holds Jinja templates for per-instance manifest rendering (multi-instance services); single-instance services keep using static `manifests/*.yaml`; file naming follows `<NNN>-<service>-<role>.yml.j2`.
- [ ] 3.2 Create `ansible/playbooks/templates/088-postgrest-config.yml.j2`. Contains a Deployment + Service for the per-app PostgREST instance. Parametrised by extra-vars `_app_name`, `_url_prefix`, `_schema`. The Deployment env-block:
  ```yaml
  env:
    - name: PGRST_DB_URI
      valueFrom: { secretKeyRef: { name: "{{ _app_name }}-postgrest", key: PGRST_DB_URI } }
    - name: PGRST_DB_SCHEMAS
      value: "{{ _schema }}"
    - name: PGRST_DB_ANON_ROLE
      value: "{{ _app_name }}_web_anon"
    - name: PGRST_ADMIN_SERVER_PORT
      value: "3001"
    - name: PGRST_SERVER_CORS_ALLOWED_ORIGINS
      value: "*"
  ```
  Add liveness probe (HTTP GET `/live` on 3001) and readiness probe (HTTP GET `/ready` on 3001) per Decision #10. Resource requests/limits per the table in the investigate (50m/500m CPU, 64Mi/256Mi memory). 2 replicas. Pin the image — set `SCRIPT_IMAGE` in `service-postgrest.sh` to `postgrest/postgrest:v<X.Y.Z>` (latest stable confirmed at implementation time; record the version in a code comment).
- [ ] 3.3 Create `ansible/playbooks/templates/088-postgrest-ingressroute.yml.j2`. Single Traefik IngressRoute matching `HostRegexp(\`{{ _url_prefix }}\..+\`)`, routing to the per-app Service on port 3000.
- [ ] 3.4 Create `ansible/playbooks/088-setup-postgrest.yml`. Receives `_app_name`, `_url_prefix`, `_schema` as extra-vars. Renders the two templates via `kubernetes.core.k8s` with `definition: "{{ lookup('template', 'templates/088-postgrest-config.yml.j2') }}"`. Asserts namespace `postgrest` exists. Errors clearly if the secret `<app>-postgrest` is missing in `postgrest` namespace (means configure was not run).
- [ ] 3.5 Create `ansible/playbooks/088-remove-postgrest.yml`. Removes the per-app Deployment, Service, and IngressRoute. Does not touch Postgres roles or the Secret (Decision #18 — those are removed by `configure --purge`).
- [ ] 3.6 Update `provision-host/uis/services/integration/service-postgrest.sh`:
  - Set `SCRIPT_PLAYBOOK="ansible/playbooks/088-setup-postgrest.yml"`
  - Set `SCRIPT_REMOVE_PLAYBOOK="ansible/playbooks/088-remove-postgrest.yml"`
  - Confirm `SCRIPT_CHECK_COMMAND` matches Decision #22 (the existing value already does).

### Validation

```bash
# Configure first (Phase 2)
./uis configure postgrest --app testapp --database testapp_db --schema api_v1 --url-prefix api-testapp

# Render-only check (no apply)
ansible-playbook ansible/playbooks/088-setup-postgrest.yml \
  -e "_app_name=testapp _url_prefix=api-testapp _schema=api_v1" \
  --check --diff

# Real deploy
./uis deploy postgrest --app testapp
kubectl get deploy testapp-postgrest -n postgrest
kubectl get svc testapp-postgrest -n postgrest
kubectl get ingressroute testapp-postgrest -n postgrest

# Smoke test
curl -fsS http://api-testapp.localhost/ | jq .swagger
# Expect: "2.0"  (PostgREST 14.x emits Swagger 2.0 / OpenAPI 2.0)
```

User confirms the deploy succeeds and the OpenAPI endpoint returns valid JSON.

---

## Phase 4: CLI dispatch — `--app` passthrough in `uis-cli.sh`

Wires the user-facing CLI to the multi-instance flag (Decision #23, gap #2 closure).

### Tasks

- [ ] 4.1 Modify `provision-host/uis/manage/uis-cli.sh` to read `multiInstance` from `services.json` for the target service when handling `deploy`, `undeploy`, `verify`, and `status` subcommands.
- [ ] 4.2 When `multiInstance: true`:
  - **Require `--app <name>`**. Error with `"Service '<id>' is multi-instance and requires --app <name>. Example: ./uis deploy <id> --app atlas"` if missing.
  - **Translate `--app <name>` into `--extra-vars "_app_name=<name>"`** when invoking the playbook (matches the existing `_target` convention from `contributors/rules/provisioning.md`).
  - For `undeploy`, also pass `_app_name` to the remove playbook.
  - For `verify` (PLAN-003) and `status`, behavior is defined here as a stub: reject `--app` if `multiInstance: false`; require it if `multiInstance: true`. The actual verify and status implementations are PLAN-003 and PLAN-005 work — this phase only establishes the CLI-level contract.
- [ ] 4.3 When `multiInstance: false` (every other service): existing behavior unchanged. Reject `--app` flag with a clear "Service '<id>' does not accept --app" error to avoid silent ignore.

### Validation

```bash
# Multi-instance happy path
./uis deploy postgrest --app testapp

# Missing --app on multi-instance service
./uis deploy postgrest
# Expect: error requiring --app

# --app on single-instance service
./uis deploy postgresql --app foo
# Expect: error rejecting --app

# Existing single-instance services still work
./uis deploy redis
# Expect: no behavior change
```

User confirms behavior matches spec for all four cases.

---

## Phase 5: Contributor documentation updates

The new conventions (`multiInstance` flag, `ansible/playbooks/templates/`, `--app <name>` lifecycle) must be teachable to the next contributor. Per the investigate's "Files to Modify" section.

### Tasks

- [ ] 5.1 Update `website/docs/contributors/guides/adding-a-service.md`. Add a new section "Multi-instance services" covering: when to use (`--app <name>` lifecycle), the `SCRIPT_MULTI_INSTANCE="true"` flag, the templates directory and Jinja convention, the `_app_name` / `_url_prefix` / `_schema` extra-var contract, the `lookup('template', ...) + kubernetes.core.k8s: definition:` pattern. Cross-reference INVESTIGATE-postgrest.md as the worked example.
- [ ] 5.2 Update `website/docs/contributors/rules/provisioning.md`. Document `_app_name` alongside the existing `_target` extra-var rule. Note that multi-instance services receive the per-instance app name as `_app_name`.
- [ ] 5.3 Update `website/docs/contributors/rules/kubernetes-deployment.md`. Clarify the split: `manifests/` for static single-instance YAML; `ansible/playbooks/templates/` for rendered per-instance YAML.
- [ ] 5.4 Run `cd website && npm run build`. Confirm the contributor docs render and sidebars resolve.

### Validation

User reads the updated `adding-a-service.md` and confirms a new contributor could follow it to add a second multi-instance service without re-reading the postgrest investigate.

---

## Phase 6: End-to-end validation

A full happy-path walk-through against a clean cluster, then the cleanup and edge cases.

### Tasks

- [ ] 6.1 Clean state: `./uis configure postgrest --app testapp --purge` (or `kubectl delete ns postgrest && drop role …` if testing on a fresh cluster).
- [ ] 6.2 Create a tiny `api_v1` schema in postgresql:
  ```sql
  CREATE DATABASE testapp_db;
  \c testapp_db
  CREATE SCHEMA api_v1;
  CREATE TABLE _internal AS SELECT 1 AS x;  -- should NOT be exposed
  CREATE VIEW api_v1.kommune AS SELECT 1 AS kommune_nr, 'Oslo' AS name;
  ```
- [ ] 6.3 `./uis configure postgrest --app testapp --database testapp_db --url-prefix api-testapp`
- [ ] 6.4 `./uis deploy postgrest --app testapp`
- [ ] 6.5 Run the four smoke checks from the investigate's "End-to-end verification" section:
  ```bash
  curl -fsS http://api-testapp.localhost/ | jq .swagger              # "2.0"
  curl -fsS http://api-testapp.localhost/kommune | jq 'length > 0'   # true
  curl -sS -o /dev/null -w '%{http_code}\n' \
      http://api-testapp.localhost/_internal                          # 404
  curl -sS -X OPTIONS -H 'Origin: https://example.com' \
      -H 'Access-Control-Request-Method: GET' \
      http://api-testapp.localhost/kommune -i | grep -i access-control-allow-origin
  ```
- [ ] 6.6 Add a second view, signal reload, verify it appears:
  ```sql
  CREATE VIEW api_v1.fylke AS SELECT 03 AS fylke_nr, 'Oslo' AS name;
  NOTIFY pgrst, 'reload schema';
  ```
  ```bash
  curl -fsS http://api-testapp.localhost/fylke | jq 'length > 0'
  ```
- [ ] 6.7 Multi-instance test: configure and deploy a second instance `testapp2`. Verify both run independently in `postgrest` namespace, with separate IngressRoutes resolving to separate Deployments.
- [ ] 6.8 Undeploy: `./uis undeploy postgrest --app testapp` — confirm Deployment, Service, IngressRoute are removed but the Secret and Postgres roles remain. Re-deploy: `./uis deploy postgrest --app testapp` — confirm it works without re-configure.
- [ ] 6.9 Purge: `./uis configure postgrest --app testapp --purge` — confirm Postgres roles and Secret are removed.
- [ ] 6.10 `./uis list` shows postgrest with `instances: N configured` annotation; `./uis status` shows the day-1 minimal `N instances configured` line per Decision #19.

### Validation

User confirms every step in 6.1–6.10 passes. If 6.10 produces unexpected formatter output, capture it for PLAN-005.

---

## Acceptance Criteria

- [ ] `services.json` contains `"multiInstance": true` for postgrest and `false` (or absent) for every other service
- [ ] `./uis configure postgrest --app <name>` creates Postgres roles, the namespace, and the per-app secret; rejects `--namespace` / `--secret-name-prefix`
- [ ] `./uis deploy postgrest --app <name>` succeeds end-to-end; `curl http://api-<name>.localhost/` returns valid Swagger 2.0 JSON (PostgREST 14.x emits Swagger 2.0 / OpenAPI 2.0)
- [ ] Two configured instances coexist in the `postgrest` namespace without collision
- [ ] `./uis undeploy postgrest --app <name>` removes K8s objects but leaves Postgres roles and Secret intact for clean re-deploy
- [ ] `./uis configure postgrest --app <name> --purge` removes Postgres roles and Secret
- [ ] `./uis configure postgrest --app <name> --rotate` regenerates the password and updates the Secret
- [ ] On a cluster where postgresql is not deployed, `./uis configure postgrest --app <name>` errors with the dependency message from Decision #23
- [ ] `./uis deploy postgrest` (no `--app`) errors with the multi-instance requirement message; `./uis deploy postgresql --app foo` errors with the single-instance rejection message
- [ ] Schema reload via `NOTIFY pgrst, 'reload schema'` makes new views visible without restart
- [ ] Contributor docs `adding-a-service.md`, `provisioning.md`, and `kubernetes-deployment.md` describe the new conventions

---

## Files to Modify

**Platform infrastructure (reusable for future multi-instance services):**
- `provision-host/uis/lib/configure.sh` — add `--schema` / `--url-prefix` flag parsing, multi-instance precheck routing, helper functions
- `provision-host/uis/lib/service-scanner.sh` — emit `multiInstance` field
- `provision-host/uis/manage/uis-cli.sh` — `--app` passthrough; require/reject based on `multiInstance`
- `ansible/playbooks/templates/` *(new directory)*
- `ansible/playbooks/templates/README.md` *(new)*

**PostgREST-specific:**
- `provision-host/uis/services/integration/service-postgrest.sh` — add `SCRIPT_MULTI_INSTANCE`, `SCRIPT_PLAYBOOK`, `SCRIPT_REMOVE_PLAYBOOK`, pin `SCRIPT_IMAGE`
- `provision-host/uis/lib/configure-postgrest.sh` *(new)*
- `ansible/playbooks/templates/088-postgrest-config.yml.j2` *(new)*
- `ansible/playbooks/templates/088-postgrest-ingressroute.yml.j2` *(new)*
- `ansible/playbooks/088-setup-postgrest.yml` *(new)*
- `ansible/playbooks/088-remove-postgrest.yml` *(new)*

**Contributor documentation:**
- `website/docs/contributors/guides/adding-a-service.md` — multi-instance section
- `website/docs/contributors/rules/provisioning.md` — `_app_name` extra-var
- `website/docs/contributors/rules/kubernetes-deployment.md` — manifests vs templates split

**Auto-regenerated (do not hand-edit):**
- `website/src/data/services.json` — picked up by `./uis docs generate`

**Not touched (deferred to later plans):**
- `ansible/playbooks/088-test-postgrest.yml` — PLAN-003 (verify)
- JWT / Authentik wiring — PLAN-004
- `./uis status` per-instance row formatting — PLAN-005
- `provision-host/uis/templates/secrets-templates/` — per-app secrets are dynamic, not templated (per investigate's "Note on secrets templates")
- `provision-host/uis/lib/stacks.sh` — postgrest is standalone (Decision #8)
- `manifests/` — postgrest renders per-app, no static manifest

---

## Implementation Notes

**Order of work within a phase matters.** Phase 2's tasks 2.1 → 2.4 must happen in order: flag parsing exists before the handler can be dispatched; the handler exists before idempotency tests pass.

**The `multiInstance` flag is the load-bearing piece.** If anything breaks in unexpected ways during implementation, look at how the flag is read first. Three places consume it: `configure.sh` (precheck routing), `uis-cli.sh` (lifecycle dispatch), and the Phase 5 formatters (later — PLAN-005). All three read from `services.json`, so the scanner change in 1.2 must be tested before any consumer code.

**Re-use over re-implement.** `configure-postgresql.sh` already has working patterns for kubeconfig discovery, pod lookup, namespace creation, and secret creation. Mirror them in `configure-postgrest.sh` rather than diverging. The PLANS.md "Library Reuse Rules" apply.

**Image version pinning.** Decision #7 in the investigate punts the exact PostgREST version to "latest stable confirmed during implementation." Confirm via `https://github.com/PostgREST/postgrest/releases`, pin the patch version, and record the date in a comment in `service-postgrest.sh`. Per UIS practice (`INVESTIGATE-system-version-pinning.md`), do not use `:latest`.

**Idempotency vs `--rotate` is a foot-gun.** The default no-op behavior means an operator can re-run `configure` without consequence. `--rotate` is destructive (invalidates running PostgREST connections until rollout-restart). Make sure the `--rotate` code path emits a clear warning before proceeding, and document the rollout-restart requirement in the user-facing docs.

---

## Out of Scope

- The verification playbook `088-test-postgrest.yml` — that is PLAN-003. End-to-end smoke checks in Phase 6 of this plan are *manual* validation, not automation.
- JWT/Authentik integration. PostgREST runs anonymous-only after this plan. PLAN-004 layers auth on top.
- Full per-instance reporting in `./uis status` (one row per app with ready/desired). Day-1 reporting from Decision #19 is the count-only line. PLAN-005 polishes the formatter.
- Backstage `kind: API` per-instance metadata generation. Decision #9 defers this until Backstage is actually deployed.
- pg_graphql / GraphQL exposure of `api_v1`. Separate `INVESTIGATE-pg-graphql.md`.
- Adding postgrest to any stack. Decision #8 — postgrest is standalone, deploys are always explicit `--app`.

---

## What success looks like

After PLAN-002 lands, an operator on a fresh cluster runs:

```bash
./uis deploy postgresql
psql -c "CREATE DATABASE atlas_db; …"
./uis configure postgrest --app atlas --database atlas_db --url-prefix api-atlas
./uis deploy postgrest --app atlas
curl http://api-atlas.localhost/kommune
```

…and gets JSON back. They configure a second app (`./uis configure postgrest --app customers --database customers_db --url-prefix api-customers && ./uis deploy postgrest --app customers`) and both run independently. They run `./uis configure postgrest --app atlas --rotate` and the password rotates without breaking the second app. They follow the updated `adding-a-service.md` to scaffold a hypothetical second multi-instance service without consulting the postgrest investigate.

If those things work, PostgREST is shipped and the multi-instance pattern is a real, documented platform capability.
