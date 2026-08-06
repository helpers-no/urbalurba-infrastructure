# Feature: let `uis undeploy` remove the database it created

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: Make a genuinely clean reinstall possible, so install bugs cannot hide
behind leftover state.

**Investigation**: [INVESTIGATE-service-litellm-install-reliability.md](./INVESTIGATE-service-litellm-install-reliability.md)

**Priority**: Medium

**Last Updated**: 2026-08-06

---

## Problem

`210-remove-litellm.yml` states plainly:

```
# Note: The PostgreSQL database 'litellm' is NOT deleted.
```

Keeping user data by default is the right instinct. The problem is that there is
**no supported way to remove it**, which means:

- **Install bugs are unfalsifiable.** Every reinstall after the first lands on an
  existing schema, so a broken first-install path stays hidden. This is exactly
  how finding F2 went unnoticed — the failure only became visible after dropping
  the database by hand.
- Testing an install requires knowing the internals: which database, which role,
  and that `u10-litellm-create-postgres.yml` already has a `delete` mode.
- The same gap applies to every UIS service with a database.

The capability already exists and is simply never invoked: `u10` implements
`-e operation=delete`, which terminates connections, drops the database and
drops the role.

---

## Solution

Add an explicit, opt-in purge. Never the default.

---

## Phase 1: Purge flag

### Tasks

- [ ] 1.1 Add a `--purge` (or `-e purge_data=true`) option to
      `uis undeploy litellm`
- [ ] 1.2 When set, call
      `utility/u10-litellm-create-postgres.yml -e operation=delete`
- [ ] 1.3 Require confirmation unless a `--force`/non-interactive flag is given —
      `u10` already has `1.10-FORCE. Skip confirmation for automated deletion`
- [ ] 1.4 Update the removal summary so it states what *was* deleted, replacing
      the current unconditional "database was NOT deleted" line
- [ ] 1.5 Make the default path (no flag) print how to purge, so the option is
      discoverable

### Validation

```bash
./uis undeploy litellm --purge
psql -c "select 1 from pg_database where datname='litellm'"  # -> no rows
psql -c "select 1 from pg_roles    where rolname='litellm'"  # -> no rows
./uis deploy litellm
psql -d litellm -c "select count(*) from information_schema.tables
                    where table_schema='public'"             # -> 69+
```

User confirms a clean reinstall works end to end.

---

## Phase 2: Generalise

### Tasks

- [ ] 2.1 Identify the other UIS services that create databases
      (postgresql-backed: authentik, temporal, openwebui, …)
- [ ] 2.2 Decide whether `--purge` becomes a standard `uis undeploy` option
      rather than a per-service one
- [ ] 2.3 Document the convention in the service-authoring guide

### Validation

User confirms the approach is consistent across services.

---

## Acceptance Criteria

- [ ] `uis undeploy litellm` still preserves data by default
- [ ] `--purge` removes database and role, with confirmation
- [ ] A purge followed by a deploy yields a fully populated schema
- [ ] The removal output tells the truth about what was and was not deleted
- [ ] Non-interactive use is possible for CI/testing

---

## Implementation Notes

This is the plan that makes the others testable. Without it, verifying
`PLAN-001` required a hand-written teardown that drops the database out-of-band.
Worth doing early even though it is rated Medium.

⚠️ Purge is destructive and irreversible. It must never be implied by
`undeploy` alone, and must not be reachable by a typo — prefer a long flag over
a short one.

---

## Files to Modify

- `ansible/playbooks/210-remove-litellm.yml`
- the `uis` CLI undeploy verb (argument parsing + help text)
