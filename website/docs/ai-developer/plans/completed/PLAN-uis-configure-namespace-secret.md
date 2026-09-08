# Plan: uis configure --namespace + K8s Secret creation

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed (9 unit tests + 19 integration tests passing)

**Goal**: Add `--namespace` and `--secret-name-prefix` flags to `uis configure` so DCT app templates with `requires` can deploy successfully — by ensuring the K8s Secret referenced in their deployment manifest exists in the target namespace.

**Last Updated**: 2026-04-09

**Investigation**: `helpers-no/dev-templates` → `INVESTIGATE-improve-template-docs-with-services.md` (Item 1.10, "Minimum D5"). All UIS questions answered in 7MSG.

**Priority**: High — blocks DCT 1.9 (`dev-template-configure --namespace` pass-through) and the python-basic-webserver-database template README rewrite.

**Estimated time**: 1 day

---

## Background

The `python-basic-webserver-database` template's `manifests/deployment.yaml` references a K8s Secret named `{{REPO_NAME}}-db` with a `DATABASE_URL` key. Currently, no part of the system creates this secret. When the deployment is applied, the pod crash-loops because the secret doesn't exist.

`uis configure` already creates the database, the user, and applies the init file. It needs to also create the K8s Secret in the namespace where the app will be deployed.

This is the minimum viable fix from the unified template system follow-up investigation.

---

## Specification (from 5MSG / 7MSG)

### New flags

```
uis configure <service> [existing flags...] --namespace <ns> --secret-name-prefix <prefix>
```

Both flags are **optional**. When neither is passed, behavior is unchanged (backward compat with `uis template install postgresql-demo`).

When `--namespace` is passed:
1. Create the namespace if missing (idempotent via `kubectl apply` of a Namespace manifest)
2. Create a K8s Secret named `<secret-name-prefix>-db` in that namespace
3. Secret has one key: `DATABASE_URL` containing the cluster URL (`postgresql://user:pass@postgresql.default.svc.cluster.local:5432/db`)
4. Idempotent — re-running updates the secret in place

When `--secret-name-prefix` is passed without `--namespace`: error (need namespace to know where to put the secret).

When `--namespace` is passed without `--secret-name-prefix`: error (need prefix to name the secret). Caller should pass both explicitly per **3DCT**.

### JSON response changes

**Add three new fields** when secret is created:
```json
{
  "secret_name": "<prefix>-db",
  "secret_namespace": "<namespace>",
  "env_var": "DATABASE_URL"
}
```

**Keep `cluster.database_url`** for one deprecation cycle (per **4DCT** / **on 4UIS+4DCT**). Remove in Phase 2.

### Idempotency

Re-running `uis configure` with the same args:
- Database/user already exist → password reset (existing behavior, **already_configured** branch from PR #119)
- Namespace exists → no-op
- Secret exists → updated in place via `kubectl apply` (so the new password is propagated)
- Returns the new connection details + secret info on success

### Scope

- **PostgreSQL only** for Phase 1
- Other configurable services (mysql, mongodb, redis, authentik) follow the same pattern when a real template needs them

---

## Phase 1: Argument parsing

### Tasks

- [x] 1.1 Add `--namespace` and `--secret-name-prefix` flags to `configure.sh` argument parser
- [x] 1.2 Validate: if either flag is set, both must be set (return JSON error with `phase: usage` if not)
- [x] 1.3 Pass both values through to the per-service handler (`configure_service` signature changes)

### Validation

- `uis configure postgresql --app a --database b --json` (no namespace flags) — works, no secret created, response unchanged from current
- `uis configure postgresql --app a --database b --namespace ns --json` — error: missing `--secret-name-prefix`
- `uis configure postgresql --app a --database b --secret-name-prefix p --json` — error: missing `--namespace`

---

## Phase 2: Namespace + Secret creation in PostgreSQL handler

### Tasks

- [x] 2.1 Add `_pg_ensure_namespace <name>` helper that does `kubectl create namespace --dry-run=client -o yaml | kubectl apply -f -`
- [x] 2.2 Add `_pg_create_secret <namespace> <secret_name> <database_url>` helper that uses `kubectl create secret generic --dry-run=client -o yaml | kubectl apply -f -` (idempotent)
- [x] 2.3 In `configure_service` (PostgreSQL handler):
  - After successful database/user creation OR password reset
  - If `namespace` is set, call `_pg_ensure_namespace`
  - Build the cluster URL with the new password
  - Call `_pg_create_secret` with the cluster URL

### Validation

- After running with `--namespace ns --secret-name-prefix p`:
  - `kubectl get namespace ns` succeeds
  - `kubectl get secret p-db -n ns -o jsonpath='{.data.DATABASE_URL}' | base64 -d` returns the cluster URL with the new password
- Re-running updates the secret (verify password in secret matches the latest password from JSON output)

---

## Phase 3: JSON response

### Tasks

- [x] 3.1 Add `secret_name`, `secret_namespace`, `env_var` to the JSON response for both `ok` and `already_configured` paths
- [x] 3.2 Keep `cluster.database_url` as before (deprecation period — remove in Phase 2 of the investigation)
- [x] 3.3 Update the human-readable progress messages on stderr to mention secret creation

### Validation

- JSON response has all expected fields when `--namespace` is set
- JSON response is unchanged when `--namespace` is NOT set (no `secret_*` fields, `cluster.database_url` still present)
- Both `ok` and `already_configured` paths return the same shape (per Gap 1 fix from PR #119)

---

## Phase 4: Tests

### Tasks

- [x] 4.1 Add unit test for argument parsing edge cases (one flag without the other)
- [x] 4.2 Add integration test that validates:
  - Namespace gets created
  - Secret gets created with correct name and DATABASE_URL key
  - Secret gets updated on re-run with new password
  - Secret persists across `uis configure` calls

---

## Files Changed

| File | Change |
|------|--------|
| `provision-host/uis/lib/configure.sh` | Add `--namespace`, `--secret-name-prefix` flag parsing, pass to handler |
| `provision-host/uis/lib/configure-postgresql.sh` | Add namespace/secret creation, add fields to JSON response |
| `provision-host/uis/tests/unit/test-configure-namespace.sh` | New unit tests |
| `provision-host/uis/tests/deploy/test-configure-namespace-integration.sh` | New integration test |

---

## Dependencies

- PostgreSQL deploy must work — already does
- `kubectl` must be available — always is in provision-host
- `urbalurba-secrets` must be applied — already part of deploy flow
- No DCT or TMP dependency — this work is fully independent. DCT 1.9 starts after this lands.

## Coordination

After landing:
- Notify DCT in talk file — they can start 1.9
- Notify TMP in investigation message — they can use the new flags in README rewrite

## References

- `helpers-no/dev-templates` → `INVESTIGATE-improve-template-docs-with-services.md` Items 1.10, 1.11
- Messages: 1MSG, 3MSG, 5MSG (1UIS, 2UIS, 3UIS, 4UIS), 6MSG (3DCT, 4DCT), 7MSG
- PR #119 — most recent fixes to `uis configure` (Gap 1/2/3 from DCT integration tests)
- `python-basic-webserver-database/manifests/deployment.yaml` — secret reference convention (`{{REPO_NAME}}-db`)
