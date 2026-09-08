# Investigate: PostgREST `--schemas` flag and reconfigure semantics

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: Decide what `./uis configure postgrest --app <name> --schemas <list>` means when called more than once with a *changing* list. The single-schema handler that PLAN-002 shipped never had to reconcile across calls; multi-schema does.

**Last Updated**: 2026-05-06 (resolutions recorded; concise rewrite)

**Origin**: Atlas asked for `marts` + `raw` exposure alongside `api_v1` (cross-repo talk thread, atlas Messages 1–3). UIS counter-proposed a per-app `--schemas` flag (uis Message 1). Atlas confirmed direction in Message 3. Before PLAN-XXX drafting, terje raised the reconfigure question: *"can the command be run many times — what happens if it's run with 3 schemas and then I remove one and run again?"* This investigation answers that.

**Depends on**: [INVESTIGATE-postgrest.md](INVESTIGATE-postgrest.md), [PLAN-002-postgrest-deployment.md](./PLAN-002-postgrest-deployment.md), the existing `configure-postgrest.sh` handler.

---

## Resolutions (2026-05-06)

Five decisions settle the design.

### R1 — Wipe + rewrite (not diff)

Every non-no-op configure resolves to:

```sql
BEGIN;
DROP OWNED BY <app>_web_anon;          -- clears all schema USAGE/SELECT + pg_default_acl entries in this DB
GRANT USAGE  ON SCHEMA <s_i> TO <app>_web_anon;
GRANT SELECT ON ALL TABLES IN SCHEMA <s_i> TO <app>_web_anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA <s_i> GRANT SELECT ON TABLES TO <app>_web_anon;
-- ... per schema in --schemas
COMMIT;
```

`DROP OWNED BY` revokes all privileges granted to the role (per PG 16 docs), including `pg_default_acl` entries — the stealth-persistence problem from "remove a schema" goes away for free. End state is fully determined by `--schemas`; no diff state needed. Single transaction is naturally atomic. Code is roughly half the size of diff-based reconciliation.

The `<app>_authenticator → <app>_web_anon` role membership survives `DROP OWNED BY` (cluster-level grant in `pg_auth_members`, not a per-database privilege). Verify with a test.

**Tradeoff**: out-of-band `GRANT … TO <app>_web_anon` is wiped on the next configure. Documented as "the role's grants are exclusively UIS-managed."

### R2 — `PGRST_DB_SCHEMAS` lives in the per-app secret

The secret (`<app>-postgrest` in postgrest namespace) gains a second key, `PGRST_DB_SCHEMAS`, holding the comma-separated schema list in operator-specified order.

- Configure writes both `PGRST_DB_URI` and `PGRST_DB_SCHEMAS` on every successful run.
- Deploy template reads `PGRST_DB_SCHEMAS` via `valueFrom.secretKeyRef`, not from a Jinja substitution.
- Both `--schemas` and `--schema` are **removed from the deploy CLI surface**. Deploy takes `--app` and `--url-prefix` only. Configure-deploy drift collapses to zero.

The role here is "memorize last applied" — used by deploy + observability, not consumed by reconciliation.

### R3 — No CLI flag for listing schemas; document the kubectl one-liner

Considered a `--list-schemas` query mode on configure. Rejected: the information is one kubectl line away, configure is a state-changing verb (mixing query + mutation muddies semantics), and the natural home for "current state of this PostgREST instance" is the deferred per-instance `./uis status` work flagged in Decision #19 of `INVESTIGATE-postgrest.md`. R1 (wipe-and-rewrite) actively *reduces* the case for a list flag.

**PLAN-XXX commitment**: `postgrest.md` gains an "Inspecting the current schema list" subsection with:

```bash
kubectl get secret <app>-postgrest -n postgrest \
  -o jsonpath='{.data.PGRST_DB_SCHEMAS}' | base64 -d
```

### R4 — Pre-validation, fail-loud

Before `BEGIN;`:

1. Trim whitespace per component, reject empty value, reject empty components after trim.
2. Reject components that don't match `^[a-zA-Z_][a-zA-Z0-9_]*$`. Closes the existing SQL-injection surface at `configure-postgrest.sh:400` where `$schema` is bash-substituted unquoted.
3. De-dupe with a logged warning.
4. For each remaining schema: `SELECT 1 FROM pg_namespace WHERE nspname=$1`. Any miss → reject naming the offender. No `IF EXISTS`, no silent skips.

Catches all input/lookup error scenarios at one chokepoint before any state mutation.

### R5 — `--schemas` is the only flag

`--schema` (singular) is removed entirely from the CLI surface, not aliased. Two flag names doing the same thing is operator confusion for zero benefit. Atlas (the only consumer) updates its `setup.md` to `--schemas` per atlas Message 3; UIS-internal docs and example commands are rewritten in the same PR. Operators passing `--schema` get the standard "unknown option" error from the CLI parser.

This applies to both the configure path and the deploy path. Deploy doesn't take a schema flag at all (R2 puts the list in the secret).

---

## State matrix

The handler must dispatch on two orthogonal state axes: **role state** (cluster-level, per-database irrelevant) and **secret state** (postgrest namespace, per-app). Nine cells. Five distinct paths.

|                                       | Both roles                  | Partial (exactly one)        | Neither role                |
|---------------------------------------|-----------------------------|------------------------------|-----------------------------|
| **Secret with `PGRST_DB_SCHEMAS`**    | No-op *or* Reconfigure-preserve-URI | Inconsistent (partial role) | Inconsistent (orphan secret) |
| **Secret without `PGRST_DB_SCHEMAS`** | Reconfigure-preserve-URI    | Inconsistent (partial role)  | Inconsistent (orphan secret) |
| **Secret missing**                    | Reconfigure-fresh-password  | Inconsistent (partial role)  | First-time                  |

### Path definitions

**First-time** — `(Neither, Missing)`. No prior state.
- Single transaction: `CREATE ROLE <app>_web_anon NOLOGIN` → `CREATE ROLE <app>_authenticator LOGIN PASSWORD '<new>' NOINHERIT` → `GRANT <app>_web_anon TO <app>_authenticator` → per-schema `GRANT USAGE` / `GRANT SELECT` / `ALTER DEFAULT PRIVILEGES` in operator order.
- Generate fresh password in shell before transaction; build `PGRST_DB_URI` from it.
- Write secret with both `PGRST_DB_URI` and `PGRST_DB_SCHEMAS` keys.
- `NOTIFY pgrst, 'reload schema'`.

**Reconfigure-preserve-URI** — `(Both, With-key)` when list differs, `(Both, Without-key)` always.
- Single transaction: `DROP OWNED BY <app>_web_anon` → per-schema `GRANT USAGE` / `GRANT SELECT` / `ALTER DEFAULT PRIVILEGES` in operator order. Password and authenticator role untouched.
- Read existing secret's `PGRST_DB_URI` value; write back verbatim. Always (re)write `PGRST_DB_SCHEMAS` to the normalized incoming list.
- `NOTIFY pgrst, 'reload schema'`.
- This path is also the canonical PLAN-002 → multi-schema upgrade route: existing secret has `PGRST_DB_URI` only, no `PGRST_DB_SCHEMAS`; the path adds the missing key while preserving URI and grant semantics for the previously-configured schema (typically `api_v1`).

**Reconfigure-fresh-password** — `(Both, Missing)`. Recovery from a manually-deleted secret.
- The password lived only in the deleted secret's URI; it's unrecoverable.
- Generate fresh password in shell. Single transaction: `ALTER USER <app>_authenticator WITH PASSWORD '<new>'` → `DROP OWNED BY <app>_web_anon` → per-schema GRANTs.
- Write new secret with both keys (URI built from the new password).
- `NOTIFY pgrst, 'reload schema'`.

**No-op** — `(Both, With-key)` when secret's `PGRST_DB_SCHEMAS` exact-string-equals the normalized incoming list (string-equal preserves order).
- No SQL, no secret rewrite.
- Log "already configured — nothing to do."

**Inconsistent** — every other cell. The handler does not auto-recover from operator-introduced corruption.
- `(Partial, *)`: one role exists, the other doesn't. Error: *"Inconsistent role state for app '<app>': role `<rolename>` exists but `<other>` does not. Run `./uis configure postgrest --app <app> --purge` to clear and retry."*
- `(Neither, With-key)` and `(Neither, Without-key)`: roles dropped externally; the secret references nonexistent roles. Error: *"Orphan secret: `<app>-postgrest` exists but neither role exists. Run `./uis configure postgrest --app <app> --purge` to clear and retry."*

In all inconsistent cases, the handler exits non-zero with the named error and changes no state.

### State-detection helpers

The handler needs three boolean queries to place itself on the matrix:
- `_pgrst_role_exists "<app>_web_anon"` (already exists in PLAN-002 code)
- `_pgrst_role_exists "<app>_authenticator"` (already exists)
- `_pgrst_get_secret_schemas "<app>"` returns the `PGRST_DB_SCHEMAS` value, empty if key missing, or a sentinel if the secret itself doesn't exist (e.g., empty + a separate `_pgrst_secret_exists` check, which already exists)

Three helpers, three booleans, nine cells, five paths. Every dispatch decision is one shell-level `case` statement in the handler.

---

## Scenario matrix

Every input scenario maps to one State Matrix cell or to pre-flight rejection.

| # | Scenario | Resolved by |
|---|---|---|
| A | First-time configure | First-time path |
| B | Re-run, identical list | No-op |
| C | Add a schema | Reconfigure-preserve-URI |
| D | Remove a schema | Reconfigure-preserve-URI — `DROP OWNED BY` clears stealth `pg_default_acl` for free |
| E | Replace (C + D) | Reconfigure-preserve-URI |
| F | First-time with non-existent schema | Pre-validation reject (R4) — never reaches state matrix |
| G | Re-run after schema dropped externally | Pre-validation reject (R4) — same as F |
| H | `--rotate` interaction | Preserves `PGRST_DB_SCHEMAS`; fail-loud if key missing (Final contract §6) |
| I | `--purge` interaction | Unchanged from PLAN-002 |
| J | Configure ↔ deploy drift | Eliminated by R2 (single source of truth) |
| K | Whitespace / empty / duplicate input | Pre-validation reject (R4) |
| L | Order significance | No-op vs Reconfigure-preserve-URI distinguished by string-equal comparison (preserves order) |
| M | PostgREST schema-cache reload | `NOTIFY pgrst, 'reload schema'` after non-no-op paths (Final contract §4) |
| N | Recovery: secret deleted manually | Reconfigure-fresh-password (`ALTER USER` + new secret) |
| O | PLAN-002-era upgrade (secret without `PGRST_DB_SCHEMAS`) | Reconfigure-preserve-URI |
| P | Partial role state (one role exists, the other doesn't) | Inconsistent — error and refuse to act |
| Q | Orphan secret (secret exists, neither role does) | Inconsistent — error and refuse to act |

---

## Source of truth

R2 selects S1 (per-app secret). Brief comparison kept for the reasoning trail:

| Option | Verdict |
|---|---|
| **S1** ✅ `PGRST_DB_SCHEMAS` key on per-app secret | Wins. Order preserved; deploy reads via `secretKeyRef`; secret lifecycle already aligned with configure. |
| S2 Derive from `pg_namespace` × `has_schema_privilege` | Can't preserve order; can't distinguish UIS-managed from manual grants. |
| S3 Annotation on Deployment / per-app ConfigMap | Forces configure to write a k8s object that deploy is supposed to own. |
| S4 No state — additive only, narrow only via `--purge` | Loses the entire premise of `--schemas` as a reconfigure contract. |

---

## Final contract (PLAN-XXX implements this)

The handler is fully described by the resolutions and state matrix above. This section restates the handler-level invariants — design *consequences* of R1–R5 + the state matrix, not new design.

1. **Pre-flight validation** runs before any state inspection or SQL. See R4 for the normalize/validate sequence. Empty value or any miss → reject; no SQL fires; no state inspected.

2. **State-matrix dispatch** (after pre-flight): three booleans (web_anon exists, authenticator exists, schema-list value from secret) place the call on one of the nine cells. Five paths: First-time, Reconfigure-preserve-URI, Reconfigure-fresh-password, No-op, Inconsistent. Behavior per cell defined in §State Matrix.

3. **Atomicity**: every path that runs SQL wraps the whole block in a single transaction (`BEGIN; … COMMIT;`). On any error inside the transaction, Postgres rolls back; no partial state.

4. **NOTIFY**: every path that commits SQL issues `NOTIFY pgrst, 'reload schema'` at the end (after the secret write). Skipped on No-op and Inconsistent. PostgREST re-parses `PGRST_DB_SCHEMAS` only at startup, so NOTIFY is moot for the order-only case (which falls under Reconfigure-preserve-URI), but the cost is zero and uniform-path is simpler than special-casing.

5. **Order-only change** (same set, different sequence) is just `(Both, With-key)` where the incoming list differs from the secret's stored value — string-equal comparison detects "different even if set-equal." Falls into Reconfigure-preserve-URI. SQL is idempotent for the unchanged grant set; only the secret value changes. Operator must redeploy for PostgREST to pick up the new default schema; the handler does NOT auto-rollout.

6. **`--rotate`** generates a new password and rewrites the secret. Reads existing `PGRST_DB_SCHEMAS` first; preserves it on the rewrite. If the key is **missing** (PLAN-002-era deployment), rotate fails with: *"`PGRST_DB_SCHEMAS` not present in secret. Run `./uis configure postgrest --app <app> --schemas <list>` first to establish the schema list, then retry rotate."* Forces an explicit upgrade-via-configure once; cleaner than a silent fallback to `api_v1`.

7. **`--purge`** unchanged from PLAN-002. `DROP OWNED BY` + `DROP ROLE` clears DB state; the secret-delete already in place removes both keys with the secret.

8. **Deploy CLI** accepts `--app` and `--url-prefix` only (per R2 + R5). Deploy template reads `PGRST_DB_SCHEMAS` via `valueFrom.secretKeyRef`. Configure CLI accepts `--schemas` (per R5), not `--schema`.

9. **Operator contract documented in postgrest.md**:
    - "The `<app>_web_anon` role's grants are exclusively UIS-managed. `./uis configure postgrest --app <app>` wipes and re-applies grants based on `--schemas`. Manual `GRANT` to this role will be lost on the next configure."
    - The kubectl listing one-liner from R3.
    - The order-significance note (first schema is PostgREST's default when `Accept-Profile` is omitted).
    - The PLAN-002 → PLAN-XXX upgrade note: a no-op `./uis configure postgrest --app <app> --schemas <list>` once populates the new `PGRST_DB_SCHEMAS` secret key (Reconfigure-preserve-URI path; password unchanged).

---

## Open questions

1. **Reconcile-failure half-states.** kubectl/network failure between transaction commit and secret update leaves DB grants ahead of secret. Re-running with same `--schemas` reconciles correctly via §4. Acceptable.
2. **Concurrent operators.** Two simultaneous `./uis configure postgrest --app atlas`: DB transactions serialise, secret writes don't, last-writer-wins. Real-world likelihood ≈ 0.

---

## Out of scope

- **Authenticated schemas / role-pairs.** Atlas's `private_marts` / `private_raw` belong behind a separate role-pair on a separate PostgREST instance — PLAN-003 (JWT/Authentik) territory.
- **Per-table grant control.** `--schemas` is schema-granularity; per-table whitelist/blacklist is not in scope.
- **Schema-list defaults that vary per consumer.** UIS stays domain-agnostic — default is `api_v1`; everything else is the operator's call.
- **Atlas-side documentation updates.** Atlas owns its `setup.md`; UIS doesn't write into the atlas repo.
