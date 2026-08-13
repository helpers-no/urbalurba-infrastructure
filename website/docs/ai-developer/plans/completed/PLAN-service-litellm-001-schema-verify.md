# Fix: verify the LiteLLM database schema, repair it, and fail loudly

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Completed

**Goal**: `uis deploy litellm` must never report success when the database
schema was not created.

**Investigation**: [INVESTIGATE-service-litellm-install-reliability.md](../backlog/INVESTIGATE-service-litellm-install-reliability.md)

**Priority**: High

**Last Updated**: 2026-08-06

**Completed**: 2026-08-06

---

## Problem

On a clean install the chart's migration Job fails with `P1000` and exits
`Completed` anyway. The playbook never checks the schema, so the deploy reports
`✅ SUCCESS` with an empty database. The proxy appears healthy because models are
served from the ConfigMap, but virtual keys, spend tracking and budgets fail
silently. See findings F2–F4 in the investigation.

## Solution

Add a verification block at the end of `210-setup-litellm.yml` that:

1. counts tables in the `litellm` schema,
2. runs `prisma migrate deploy` inside the pod if the schema is missing,
3. restarts the deployment and waits for it to serve,
4. **fails the play** if the schema is still absent.

Deliberately *not* attempting to fix the credentials — they were proven correct
(F3). This detects and repairs an upstream failure whose root cause is not yet
established.

---

## Phase 1: Verification and repair — ✅ DONE

### Tasks

- [x] 1.1 Add task `20a` — read the LiteLLM DB password from `urbalurba-secrets`
      in the `ai` namespace (`no_log: true`)
- [x] 1.2 Add task `20b` — count tables via `kubectl exec` into the `postgresql`
      pod's first container (which carries `psql`); pass the password through the
      task `environment` rather than the command line
- [x] 1.3 Add task `20c` — display the table count
- [x] 1.4 Add task `20d` — when fewer than 50 tables, locate
      `litellm_proxy_extras/schema.prisma` in the pod and run
      `prisma migrate deploy`
- [x] 1.5 Add task `20e` — re-count after repair
- [x] 1.6 Add task `20f` — restart the deployment so it picks up the schema
- [x] 1.7 Add task `20g` — `ansible.builtin.fail` with an actionable message if
      the schema is still missing

### Validation

```bash
psql -d litellm -c "select count(*) from information_schema.tables
                    where table_schema='public'"   # -> 69+
```

---

## Phase 2: Readiness — ✅ DONE

Discovered during Phase 1 validation: the play returned while the restarted pod
was still starting, so an immediate `/v1/models` query returned an empty list
(finding F5).

### Tasks

- [x] 2.1 Add task `20f2` — `kubectl rollout status --timeout=240s` after the
      restart
- [x] 2.2 Add task `20f3` — poll `/v1/models` until it answers `200` or `401`
      (retries: 20, delay: 6)

### Validation

Five consecutive clean cycles report 5 models rather than 0.

---

## Acceptance Criteria

- [x] A clean install (database and role dropped) produces a populated schema
- [x] The play fails, rather than printing SUCCESS, when the schema cannot be created
- [x] `/v1/models` answers before the play returns
- [x] Virtual key generation works after install
- [x] Repeatable across multiple clean cycles

---

## Verification performed

Five full teardown → install cycles, each starting from
`drop database litellm; drop role litellm`:

| | schema | serving-pod auth errors | models | completion |
|---|---|---|---|---|
| run 1 | 69 tables ✅ | 0 | 5 | `'CLEAN'` |
| run 2 | 69 tables ✅ | 0 | 5 | `'CLEAN'` |
| run 3 | 77 tables ✅ | 0 | 5 | `'CLEAN'` |
| run 4 | 69 tables ✅ | 0 | 5 | `'CLEAN'` |
| run 5 | 77 tables ✅ | 0 | 5 | `'CLEAN'` |

Before the fix the same procedure produced `0 tables` with `failed=0`.

The upstream migration Job still logs `P1000` on some runs (4 occurrences in two
of the five cycles, 0 in the others). Task `20d` repairs it; the **serving pod**
has zero auth errors in all runs. Table counts differ (69 vs 77) depending on
whether the upstream Job succeeded before the repair ran — both are complete
schemas.

---

## Implementation Notes

- The `postgresql` shim's **first** container is `postgres:18` and carries
  `psql`, which is what makes the table count possible without adding an image.
- The password is passed via the task `environment:` (`PGPW`), never as a
  command-line argument, so it does not appear in process listings.
- The 50-table threshold distinguishes "no schema" from "complete schema"
  (69+) without being brittle about the exact count, which grows with each
  upstream migration.

---

## Files to Modify

- `ansible/playbooks/210-setup-litellm.yml`
