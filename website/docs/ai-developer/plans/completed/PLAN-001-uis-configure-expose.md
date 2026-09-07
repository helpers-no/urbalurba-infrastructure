# Plan: UIS Configure and Expose Commands

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed (Phases 1-3, 5. Phase 4 deferred — separate plans per service handler.)

**Goal**: Implement `uis configure` and `uis expose` commands so DCT templates can create per-app databases/users and reach K8s services from the devcontainer.

**Last Updated**: 2026-04-04

**Investigation**: `helpers-no/dev-templates` → `INVESTIGATE-unified-template-system.md` — all specs, decisions, and JSON formats agreed with TMP and DCT contributors (decisions #1–#13, comments 1UIS–11UIS).

**Priority**: Medium — blocks DCT Phase B but independent of TMP Phase 1 and DCT Phase A.

---

## Overview

Two new commands for the UIS CLI that enable the DCT↔UIS bridge for service-dependent templates:

1. **`uis configure <service>`** — creates per-app databases/users in a running service, returns connection details as JSON
2. **`uis expose <service>`** — exposes K8s service ports to the host machine so DCT can reach them via `host.docker.internal`

Plus metadata changes to `services.json` and a `/usr/local/bin/uis` symlink in the container.

---

## Phase 1: Foundation — Symlink, services.json fields, command routing

### Tasks

- [x] 1.1 Add `/usr/local/bin/uis` wrapper to `Dockerfile.uis-provision-host`:
  Used a wrapper script (not symlink) because `BASH_SOURCE[0]` resolves to the symlink location, breaking relative path resolution in `uis-cli.sh`. The wrapper uses `exec` to forward to the real script:
  ```dockerfile
  RUN echo '#!/bin/bash' > /usr/local/bin/uis && \
      echo 'exec /mnt/urbalurbadisk/provision-host/uis/manage/uis-cli.sh "$@"' >> /usr/local/bin/uis && \
      chmod +x /usr/local/bin/uis
  ```
  This enables DCT to call `docker exec uis-provision-host uis <command>` (see 3UIS).

- [x] 1.2 Add `configurable` field to `services.json` for each service:
  - `true` for: postgresql, mysql, mongodb, redis, elasticsearch, qdrant, authentik
  - `false` for all others (grafana, prometheus, argocd, etc.)
  - TMP's validation script uses this to check `requires` values (see 9UIS).

- [x] 1.3 Add `exposePort` field to `services.json` for configurable services. Fixed well-known mappings (see 6UIS):
  - postgresql: 35432
  - mysql: 33306
  - mongodb: 37017
  - redis: 36379
  - elasticsearch: 39200
  - qdrant: 36333
  - authentik: 39000

- [x] 1.4 Add `configure` and `expose` subcommand routing to `uis-cli.sh` (stub implementations that print "not yet implemented").

- [x] 1.5 Update both schema files (`provision-host/uis/schemas/service.schema.json` and `website/src/data/schemas/service.schema.json`) with `configurable` and `exposePort` fields. All validations pass.

- [x] 1.6 *(Added during implementation)* Update `.dockerignore` to include `website/src/data/` — `configure.sh` and `expose.sh` read `services.json` for `configurable` and `exposePort` fields, so this data must be baked into the container. Added `!website/src/data` negation rule.

- [x] 1.7 *(Added during implementation)* Add `COPY --chown=ansible:ansible website/src/data/ /mnt/urbalurbadisk/website/src/data/` to `Dockerfile.uis-provision-host`.

### Validation

- `docker exec uis-provision-host uis configure` prints usage help
- `docker exec uis-provision-host uis expose` prints usage help
- `services.json` passes validation with new fields
- `uis test` passes

---

## Phase 2: `uis expose` command

### Tasks

- [x] 2.1 Create `provision-host/uis/lib/expose.sh` with:
  - `expose_service <service_id>` — starts `kubectl port-forward` in background, binds to `0.0.0.0:<exposePort>`, stores PID
  - `unexpose_service <service_id>` — kills the port-forward process
  - `expose_status` — lists currently exposed services with ports and PIDs
  - PID tracking in `/tmp/uis-expose/` (one file per service, contains PID)
  - Uses `EXPOSE_CONFIG` associative array mapping service IDs to K8s service name, namespace, and internal port

- [x] 2.2 Wire into CLI — replaced stub with real implementation:
  ```
  uis expose <service>            # start port-forward
  uis expose <service> --stop     # stop port-forward
  uis expose --status             # list exposed services
  ```

- [x] 2.3 Read port from `services.json` `exposePort` field via `jq`. K8s service names and namespaces mapped in `EXPOSE_CONFIG`.

- [x] 2.4 Handle edge cases:
  - Service not deployed → clear error with `uis deploy <service>` suggestion
  - Port already in use → detect via `ss`/`netstat` and report
  - Port-forward process died → detect on status check via PID, clean up stale PID file
  - Already exposed → reports existing port and PID, no-op
  - Unknown service → lists exposable services

### Validation

- `uis expose postgresql` starts port-forward, `psql -h localhost -p 35432` connects
- `uis expose --status` shows postgresql as exposed
- `uis expose postgresql --stop` kills the process
- `uis expose --status` shows nothing exposed
- `uis expose postgresql` when not deployed shows helpful error

---

## Phase 3: `uis configure` — PostgreSQL handler

Start with PostgreSQL only (most common service). Other handlers added later.

### Tasks

- [x] 3.1 Create `provision-host/uis/lib/configure.sh` with the main `configure` command logic:
  1. Parse args: `<service> --app <name> [--database <name>] [--init-file -] --json`
  2. Validate service is configurable (check `services.json` `configurable` field)
  3. Check service is deployed (uses `checkCommand` from `services.json` — see 4UIS)
  4. Dispatch to per-service handler (`configure-<service>.sh`)

- [x] 3.2 Create `provision-host/uis/lib/configure-postgresql.sh`:
  1. Read admin password from `urbalurba-secrets` PGPASSWORD via kubectl
  2. Check if database already exists (idempotency — 7UIS option b):
     - If exists: return `{"status": "already_configured", ...}`
     - If not: proceed with creation
  3. Generate per-app password (`openssl rand -base64 24`)
  4. `kubectl exec` into postgresql pod:
     - `CREATE USER <app_name> WITH PASSWORD '<generated>'`
     - `CREATE DATABASE <db_name> OWNER <app_name>`
     - `GRANT ALL PRIVILEGES ON DATABASE <db_name> TO <app_name>`
  5. Apply init file if provided via stdin (`psql --set ON_ERROR_STOP=on -f -`)
  6. Auto-expose if not already exposed (call `expose_service`)
  7. Return JSON on stdout with `status`, `local`, `cluster`, `database`, `username`, `password`

- [x] 3.3 Error handling — structured JSON errors on stdout (Decision #13):
  - `_configure_error` function outputs `{"status":"error","phase":"...","service":"...","detail":"..."}`
  - Phase values: `deploy_check`, `create_resources`, `init_file`, `expose`
  - Non-configurable service check returns `deploy_check` error

- [x] 3.4 Human-readable progress on stderr (all `echo ... >&2`), JSON only on stdout.

### Validation

- `uis configure postgresql --app test-app --database test_db --json` creates database and returns JSON
- Running the same command again returns `"status": "already_configured"`
- `psql -h localhost -p 35432 -U test_app -d test_db` connects with the returned password
- `uis configure postgresql --app test-app --database test_db --init-file - --json < test.sql` applies SQL
- `uis configure postgresql --json` with no postgresql deployed returns phase `deploy_check` error
- `uis configure grafana --json` returns error (not configurable)

---

## Phase 4: Additional service handlers (future)

Not in scope for this plan. Each handler is a separate small plan:

- `configure-redis.sh` — create key prefix, return connection details
- `configure-mongodb.sh` — create database/user, return connection string
- `configure-mysql.sh` — create database/user, return connection details
- `configure-authentik.sh` — apply blueprint file, return OAuth details

---

## Phase 5: Init file format documentation

### Tasks

- [x] 5.1 Create `website/docs/developing/init-file-formats.md` documenting the native format for each configurable service with links to upstream docs (see 10UIS):
  - PostgreSQL → standard SQL, with full example
  - Authentik → blueprint YAML, with example referencing UIS's actual blueprint
  - Grafana → dashboard JSON export format, with creation tips
  - Redis → TBD (noted)
  - MongoDB → TBD (noted)
  - MySQL → standard SQL (same pattern as PostgreSQL)
  - RabbitMQ → definitions JSON export format, with creation tips

- [x] 5.2 Include a working PostgreSQL example (CREATE TABLE, indexes, seed data with idempotent patterns).

### Validation

- Documentation renders correctly on the Docusaurus site
- All upstream links are valid

---

## Files Changed

| File | Change |
|------|--------|
| `Dockerfile.uis-provision-host` | Add `/usr/local/bin/uis` wrapper script (not symlink — BASH_SOURCE fix), add `website/src/data/` COPY |
| `.dockerignore` | Add `!website/src/data` negation so services.json is included in build context |
| `website/src/data/services.json` | Add `configurable` and `exposePort` fields to 7 services |
| `provision-host/uis/schemas/service.schema.json` | Add `configurable` (boolean) and `exposePort` (integer) field definitions |
| `website/src/data/schemas/service.schema.json` | Same schema additions |
| `provision-host/uis/manage/uis-cli.sh` | Add `configure` and `expose` command routing, help text, source new libs |
| `provision-host/uis/lib/expose.sh` | New — port-forward management (start/stop/status, PID tracking) |
| `provision-host/uis/lib/configure.sh` | New — main configure entry point, arg parsing, service dispatch |
| `provision-host/uis/lib/configure-postgresql.sh` | New — PostgreSQL handler (create db/user, init files, JSON output, idempotency) |
| `provision-host/uis/tests/unit/test-configure-expose.sh` | New — 33 unit tests (files, syntax, metadata, CLI routing, Dockerfile, docs) |
| `provision-host/uis/tests/deploy/test-configure-expose-integration.sh` | New — 23 integration tests (error cases, create, idempotency, init files, expose/unexpose, cleanup) |
| `website/docs/developing/init-file-formats.md` | New — init file format docs per service with upstream links |

---

## Dependencies

- PostgreSQL must be deployable (`uis deploy postgresql`) — already works
- `urbalurba-secrets` must be applied — already part of deploy flow
- No dependency on TMP or DCT — this work is fully independent

## References

- `helpers-no/dev-templates` → `INVESTIGATE-unified-template-system.md` — full specs
- Comments 2UIS (per-app credentials), 4UIS (deploy check), 6UIS (port exposure), 7UIS (configure interface), 9UIS (configurable field), 10UIS (native init formats), 11UIS (param substitution)
- Decisions #11 (Ansible deployment), #13 (error handling JSON format)
