# Fix: `configure postgrest` cannot tell "configured" from "was configured once"

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: A PostgREST instance whose database no longer carries its grants is
detected, rather than reported as configured.

**Created**: 2026-08-22, while writing
[the PostgREST verify playbook](https://github.com/helpers-no/urbalurba-infrastructure/blob/main/ansible/playbooks/088-test-postgrest.yml)
(commit `f2bd3a2`).

**Priority**: Medium — the failure is silent and the platform reports success
throughout, which is the expensive kind.

---

## Problem

`uis configure postgrest --app <name>` decides whether work is needed by checking
**the Kubernetes secret**:

```
PostgREST already configured for 'testapp' (schemas: api_v1). To proceed:
  ./uis deploy postgrest --app testapp
PostgREST already configured for 'testapp' with schemas 'api_v1' — nothing to do.
```

The secret lives in the `postgrest` namespace. The **grants** live in PostgreSQL.
Those two can come apart, and when they do nothing notices.

### Reproduction (observed 2026-08-22)

1. `configure` + `deploy` an instance — works, API serves the schema
2. Drop and recreate the database (an app team resetting, a restore from backup,
   a re-bootstrap — all ordinary)
3. `configure` again → *"already configured — nothing to do"*, `exit=0`
4. `deploy` → `exit=0`, pods `1/1 Running`
5. Every API call: `permission denied for schema api_v1`

Confirmed the grants were absent: `information_schema.role_table_grants` showed
only `postgres`, no `web_anon`. `GRANT USAGE ON SCHEMA` had never run against the
new database.

**Nothing in that sequence reports a problem.** `configure` says configured,
`deploy` says deployed, `uis status` says Healthy, the pod is Ready. The only
symptom is that the API refuses every request.

### What is NOT wrong

Worth stating, because the first reading of this was harsher and wrong:

- **`--purge` works.** It recovers the instance correctly.
- **`--purge` refuses while a Deployment exists**, and says exactly what to run
  first. That ordering is right.
- **Skipping work when nothing changed is correct behaviour.** The defect is not
  that `configure` is idempotent; it is that its idempotency key is the wrong
  object.

The gap is **detection**, not recovery.

---

## Phase 1: Check the thing that matters

### Tasks

- [ ] 1.1 Before declaring "already configured", verify the grants are actually
      present — the role exists, has `USAGE` on each configured schema, and
      `SELECT` on its tables. `configure-postgrest.sh` already builds exactly
      this GRANT block, so the check is the same query in reverse
- [ ] 1.2 On drift, do not fail: **re-apply the grants** and say so. The secret is
      still valid; only the database side is missing. Re-granting is idempotent
- [ ] 1.3 If the *database* or *schema* is gone entirely, fail with the existing
      style of message — those already exist and are good
- [ ] 1.4 Keep the fast path fast: when everything matches, still say
      "nothing to do"

### Validation

```bash
./uis configure postgrest --app x --database x --schemas api_v1
# drop and recreate database x
./uis configure postgrest --app x --database x --schemas api_v1
# -> reports drift, re-applies grants
./uis verify postgrest --app x     # passes
```

---

## Phase 2: Make the running instance say so

Configure-time detection only helps if someone runs configure. An instance can
drift while deployed.

### Tasks

- [ ] 2.1 [088-test-postgrest.yml](https://github.com/helpers-no/urbalurba-infrastructure/blob/main/ansible/playbooks/088-test-postgrest.yml)
      already catches this — test B fails with the API's own
      `permission denied for schema` in the message. Confirm the failure text
      names the likely cause rather than only the symptom
- [ ] 2.2 Consider whether `SCRIPT_CHECK_COMMAND` for postgrest should ask the
      API rather than the Deployment. A Ready pod that 403s everything currently
      reports Healthy in `uis status`

### Validation

An instance with missing grants is reported unhealthy by something other than a
user's failing request.

---

## Acceptance Criteria

- [ ] `configure` detects missing grants and re-applies them
- [ ] The fast path still short-circuits when nothing has drifted
- [ ] A drifted instance is visible without running `verify` by hand
- [ ] `--purge` behaviour is unchanged

---

## Implementation Notes

**The general shape, which is not specific to PostgREST**: an idempotency check
that reads a *marker* rather than the *state the marker stands for*. The secret
is a receipt, not the thing bought. Two other instances of the same shape are
already filed — `INVESTIGATE-secrets-dev-to-production` (validation is a
hardcoded allowlist rather than a check against the template) and
`PLAN-cli-verify-registration-fix` (registration in one list implies registration
in the others).

**A related discovery worth keeping**: PostgREST caches its schema at startup, so
a table an app adds by migration is invisible until the cache reloads. Same
signature — pod Ready, health checks green, API 404s the table. The verify
playbook handles it with `NOTIFY pgrst, 'reload schema'`; whether *UIS* should
signal a reload after an app migrates is an open question, and probably belongs
to whatever owns app migrations rather than here.

---

## Files to Modify

- `provision-host/uis/lib/configure-postgrest.sh` — the already-configured check
- `provision-host/uis/services/integration/service-postgrest.sh` — possibly
  `SCRIPT_CHECK_COMMAND`
