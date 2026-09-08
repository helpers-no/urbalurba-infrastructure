# Feature: PostgREST `--schemas` flag with wipe-and-rewrite reconciliation

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: Extend `./uis configure postgrest` to expose multiple PostgreSQL schemas via a single PostgREST instance, with deterministic reconfigure semantics.

**Last Updated**: 2026-05-06

**Completed**: 2026-05-06 — PR #140 merged (commits `feb1562` + `120327b`); CI workflows green (Build UIS Container, Test UIS Scripts, Generate UIS Documentation, Deploy Documentation); rebuilt image published as `ghcr.io/helpers-no/uis-provision-host:latest@sha256:42cd40d5f66916a6f6071ab4d69fcf0080a2915b1cf93295bd3b169b8af42f31`. Atlas validated row-flow + privacy boundary against the live deployment in cross-repo talk Message 4.

**Investigation**: [INVESTIGATE-postgrest-multi-schema-reconciliation.md](./INVESTIGATE-postgrest-multi-schema-reconciliation.md)

**Cross-repo coordination**: [atlas talk thread](file:///Users/terje.christensen/learn/helpers/atlas/website/docs/ai-developer/plans/talk/talk.md) Messages 1–4 — direction confirmed (atlas Message 3), implementation summary (uis Message 2), atlas validation green (atlas Message 4). Atlas's `setup.md` lines 294–295 update lands on their side once they pull this image.

---

## Overview

PLAN-002 shipped a single-schema PostgREST handler. Atlas now needs three schemas exposed (`api_v1`, `marts`, `raw`) and the design must support arbitrary schema-list changes across configure runs without leaking grants. The investigation settled on a wipe-and-rewrite approach (`DROP OWNED BY` + per-schema GRANTs in one transaction) with the schema list memorized in the per-app secret. Deploy reads the schema list from the secret, eliminating configure/deploy drift.

The full design is in the investigation's *Final contract* section. This plan executes it.

---

## Phase 1: Input parsing and validation

Pure CLI / handler input handling. No DB or k8s side effects.

### Tasks

- [ ] 1.1 In `provision-host/uis/manage/uis-cli.sh` `cmd_configure`: **replace** the existing `--schema` flag with `--schemas` (line 308). `--schema` falls through to the unknown-option error. Atlas is the only consumer; atlas's setup.md is being updated per atlas Message 3; the only docs / call-sites still using `--schema` are inside this repo and are all rewritten by this plan.
- [ ] 1.2 In `provision-host/uis/lib/configure.sh` `run_configure`: replace `--schema` with `--schemas` in the argument-parsing case block (line 126). Internal variable is renamed `schema` → `schemas` for clarity. The parsed value flows through to the handler via `configure_service` (line 259) — same dispatch, new name.
- [ ] 1.3 In `configure-postgrest.sh`: add a `_pgrst_normalize_schemas()` helper that takes the raw schemas value and returns the normalized comma-separated list. Steps: split on `,`, trim each component, reject empty value, reject empty components after trim, reject components not matching `^[a-zA-Z_][a-zA-Z0-9_]*$`, de-dupe while preserving first occurrence (call `log_warn` to stderr for any drop, naming the duplicate), join with `,` (no spaces).
- [ ] 1.4 In `configure-postgrest.sh` default-path entry: call the normalizer first; surface its rejections via `_configure_error "usage" …` with the offending input named in the message.
- [ ] 1.5 Update the existing usage error at `configure-postgrest.sh:166` to reference `--schemas api_v1,marts,raw` in the example.

### Validation

```bash
# Build local image (contributor-side; the tester will run the integration cycle later)
./uis build

# Sanity checks on read-only command help
docker run --rm uis-provision-host:local uis configure postgrest --help 2>&1 | grep -E '\-\-schemas?'
```

Help output mentions only `--schemas` (no `--schema`). User confirms.

---

## Phase 2: Wipe-and-rewrite reconciliation

Implement the State Matrix dispatch from the investigation. This phase is structural; SQL contents and path-by-path behavior are defined in the investigation's *State Matrix* section.

### Tasks

- [ ] 2.1 Add `_pgrst_get_secret_schemas()` helper to `configure-postgrest.sh` — reads the existing secret (if present) and returns the `PGRST_DB_SCHEMAS` value, empty string if key absent or secret missing. (Companion to existing `_pgrst_secret_exists` and `_pgrst_role_exists`.)
- [ ] 2.2 Add `_pgrst_get_secret_uri()` helper — reads `PGRST_DB_URI` from the existing secret, empty if absent. Needed for the Reconfigure-preserve-URI path.
- [ ] 2.3 After the normalize call wired in task 1.4 (string-level checks complete), add R4 step 4: per-schema existence check via `SELECT 1 FROM pg_namespace WHERE nspname=$1`. Any miss → reject naming the offender via `_configure_error "usage" …`. Must run before any state inspection (no role/secret reads happen until validation passes).
- [ ] 2.4 Implement state detection: read the three booleans (`web_anon_exists`, `authenticator_exists`, `secret_schemas_value`) and dispatch to one of the five paths from the investigation's State Matrix. One `case` statement; one helper per path. Inconsistent cells emit the error messages exactly as written in §State Matrix → "Inconsistent" subsection.
- [ ] 2.5 Implement the four non-trivial paths as separate helper functions, each containing a single SQL transaction:
  - `_pgrst_path_first_time()`
  - `_pgrst_path_reconfigure_preserve_uri()`
  - `_pgrst_path_reconfigure_fresh_password()`
  - (No-op path: just logs and returns; no helper needed.)
  
  SQL contents per the investigation's path definitions. Replace the existing CREATE-ROLE + GRANT block (`configure-postgrest.sh:386–404`).
- [ ] 2.6 Extend `_pgrst_create_secret` (or add `_pgrst_create_secret_with_schemas`) to write both `PGRST_DB_URI` and `PGRST_DB_SCHEMAS` keys. Existing single-key callers updated; rotate path also calls through this.
- [ ] 2.7 At the end of every path that committed SQL, issue `NOTIFY pgrst, 'reload schema'` via `_pgrst_exec_db` against the per-app database.
- [ ] 2.8 Update the JSON success output to include `"schemas": "<normalized list>"`. Update `_configure_error` JSON shape only if a new error code is added (none expected).

### Validation

```bash
# After tester deploys with the test brief (see Phase 7), sanity from contributor side:
docker exec uis-provision-host kubectl get secret atlas-postgrest -n postgrest \
  -o jsonpath='{.data.PGRST_DB_SCHEMAS}' | base64 -d
# Expected: api_v1,marts,raw

docker exec uis-provision-host kubectl exec -n default postgresql-0 -- \
  psql -U postgres -d atlas_db -c "\dn+"
# Expected: atlas_web_anon listed with USAGE on api_v1, marts, raw — and only those.
```

User confirms wipe-and-rewrite produces exact end state for: first-run, add-schema, remove-schema, replace-schema, order-only-change.

---

## Phase 3: Rotate path preservation + missing-key error

### Tasks

- [ ] 3.1 In `configure-postgrest.sh` rotate path (lines ~290–336): before generating the new password, read the existing secret's `PGRST_DB_SCHEMAS`. If the key is missing, error with: *"`PGRST_DB_SCHEMAS` not present in secret. Run `./uis configure postgrest --app <app> --schemas <list>` first to establish the schema list, then retry rotate."* If the key is present but malformed (e.g. operator hand-edited the secret), trust the value — re-validation isn't rotate's job; configure was the only legitimate writer.
- [ ] 3.2 On successful rotate, rewrite the secret with both `PGRST_DB_URI` (new password) and the preserved `PGRST_DB_SCHEMAS`.

### Validation

```bash
# After Phase 2 lands and atlas is configured:
docker exec uis-provision-host uis configure postgrest --app atlas --rotate
docker exec uis-provision-host kubectl get secret atlas-postgrest -n postgrest \
  -o jsonpath='{.data.PGRST_DB_SCHEMAS}' | base64 -d
# Expected: still api_v1,marts,raw (preserved across rotate).
```

User confirms rotate preserves schema list and fails loudly on PLAN-002-era secrets.

---

## Phase 4: Deploy template + playbook switch to `secretKeyRef`

### Tasks

- [ ] 4.1 In `ansible/playbooks/templates/088-postgrest-config.yml.j2`: replace the `PGRST_DB_SCHEMAS` env entry's `value: "{{ _schema }}"` with `valueFrom.secretKeyRef` pointing at the per-app secret's `PGRST_DB_SCHEMAS` key.
- [ ] 4.2 In `ansible/playbooks/088-setup-postgrest.yml`: drop `_schema` from the required-extra-vars assertion (task 1, lines 38–46).
- [ ] 4.3 In the same playbook: remove the `Schema:    {{ _schema }}` line from the debug output (task 2, lines 51–56).
- [ ] 4.4 *(Decided: skipped.)* No extra key-presence check in the playbook. Kubernetes' built-in `secretKeyRef` resolution will surface a clear `CreateContainerConfigError` ("couldn't find key PGRST_DB_SCHEMAS in Secret postgrest/<app>-postgrest") on pod start if configure wasn't run first. That error is readable enough; the rotate-path error in Phase 3.1 already forces an upgrade-via-configure before deploy.

### Validation

```bash
docker exec uis-provision-host ansible-playbook \
  /mnt/urbalurbadisk/ansible/playbooks/088-setup-postgrest.yml \
  -e "_app_name=atlas _url_prefix=api-atlas" --check
```

Dry-run completes without "missing extra-var" errors. User confirms the rendered Deployment references `valueFrom.secretKeyRef` for `PGRST_DB_SCHEMAS`.

---

## Phase 5: CLI cleanup on the deploy path

### Tasks

- [ ] 5.1 In `uis-cli.sh` `cmd_deploy` (lines ~297–371): remove `--schema` flag parsing and the `schema` local variable.
- [ ] 5.2 Remove the `schema="${schema:-api_v1}"` default and the `schema` argument from the `deploy_single_service` call.
- [ ] 5.3 In the same file's "Service is single-instance" rejection (line ~346), remove `--schema` from the disallowed-flags message (the message currently lists `--app/--url-prefix/--schema`).
- [ ] 5.4 In `provision-host/uis/services/integration/service-postgrest.sh`: update the example command at line 10 to show `--schemas` on configure and bare `./uis deploy postgrest --app <name>` on deploy.
- [ ] 5.5 In `ansible/playbooks/088-setup-postgrest.yml` (line 80): update the fail message that prints the configure-retry hint to use `--schemas <list>` instead of `--schema {{ _schema }}`.

(Note: `configure.sh` is the configure-side dispatcher only; it has no deploy-side dispatch to clean up. Phase 1.2 already migrates it from `--schema` to `--schemas`.)

### Validation

```bash
docker run --rm uis-provision-host:local uis deploy postgrest --help 2>&1 | grep -i schema
```

Expected: no mention of `--schema` or `--schemas` for the deploy subcommand. User confirms.

---

## Phase 6: Tests

Tests live at `provision-host/uis/tests/{unit,deploy}/`. Follow the existing `test-configure-namespace.sh` (unit) / `test-configure-namespace-integration.sh` (integration) naming pattern.

### Tasks

- [ ] 6.1 Add `provision-host/uis/tests/unit/test-configure-postgrest-schemas.sh` covering `_pgrst_normalize_schemas()`: valid lists; whitespace trimming; empty value rejection; empty-component rejection; identifier-regex rejection; duplicate de-dupe with warning to stderr. Plus a CLI-parsing case asserting `--schema` is rejected as an unknown option (no aliasing).
- [ ] 6.2 Add `provision-host/uis/tests/deploy/test-configure-postgrest-schemas-integration.sh` with the following cases. (Each case is a function in the file; the file mirrors the structure of `test-configure-namespace-integration.sh`.)
- [ ] 6.3 Case: first-time configure with `--schemas api_v1,marts,raw` — assert all three grants present (`SELECT has_schema_privilege('atlas_web_anon', '<schema>', 'USAGE')` per schema), secret has both keys, secret's `PGRST_DB_SCHEMAS` value equals `api_v1,marts,raw`.
- [ ] 6.4 Case: re-run with same list — assert no-op message printed, no rows changed (compare `(SELECT array_agg(nspname) FROM pg_namespace WHERE has_schema_privilege('atlas_web_anon', oid, 'USAGE'))` before/after).
- [ ] 6.5 Case: reconfigure with `--schemas api_v1,marts` — assert `raw` grants gone:
  ```sql
  SELECT count(*) = 0 FROM pg_default_acl
   WHERE defaclnamespace = (SELECT oid FROM pg_namespace WHERE nspname='raw')
     AND defaclacl::text LIKE '%atlas_web_anon%';
  SELECT NOT has_schema_privilege('atlas_web_anon', 'raw', 'USAGE');
  ```
- [ ] 6.6 Case: order-only change `api_v1,marts,raw` → `marts,raw,api_v1` — assert SQL end-state grants identical (same `pg_namespace` set), secret's `PGRST_DB_SCHEMAS` exactly equals `marts,raw,api_v1`.
- [ ] 6.7 Case: missing schema in `--schemas` (e.g. `--schemas api_v1,bogus`) — assert pre-validation rejects with a message naming `bogus`; assert no roles created (`SELECT count(*) FROM pg_roles WHERE rolname IN ('atlas_web_anon','atlas_authenticator')` = 0 if first-time, unchanged if reconfigure).
- [ ] 6.8 Case: `<app>_authenticator → <app>_web_anon` membership survives `DROP OWNED BY`. Configure first-time, run a reconfigure that triggers `DROP OWNED BY`, assert membership still present:
  ```sql
  SELECT EXISTS (
    SELECT 1 FROM pg_auth_members
     WHERE roleid  = (SELECT oid FROM pg_authid WHERE rolname='atlas_web_anon')
       AND member  = (SELECT oid FROM pg_authid WHERE rolname='atlas_authenticator')
  );
  ```
- [ ] 6.9 Case: rotate fails with the stated error message when secret has no `PGRST_DB_SCHEMAS` key (simulate by `kubectl patch secret … --type=json -p='[{"op":"remove","path":"/data/PGRST_DB_SCHEMAS"}]'` first).
- [ ] 6.10 Case: recovery — delete secret manually (`kubectl delete secret atlas-postgrest -n postgrest`), re-run configure with `--schemas api_v1,marts,raw`. Assert: secret rebuilt with both keys; password changed (auth check with the *new* secret's URI succeeds, with the prior captured URI fails); grants correct on all three schemas. Per task 2.5, this hits the "reconfigure with missing secret" sub-path with `ALTER USER … PASSWORD`.
- [ ] 6.11 Case: PLAN-002-era upgrade — write a secret with only `PGRST_DB_URI` (no `PGRST_DB_SCHEMAS`), then run configure with `--schemas api_v1,marts,raw`. Assert: secret gains `PGRST_DB_SCHEMAS`; original `PGRST_DB_URI` preserved (password unchanged); grants applied correctly.
- [ ] 6.12 Case: partial-role state — manually `DROP ROLE atlas_authenticator` (leaving `atlas_web_anon`), re-run configure. Assert: error message names the surviving role; no SQL state change; suggests `--purge`.
- [ ] 6.13 Case: deploy with no schema flags reads `PGRST_DB_SCHEMAS` from secret correctly. After configure with `--schemas api_v1,marts,raw` and `./uis deploy postgrest --app atlas`, assert OpenAPI at `http://api-atlas.localhost/` advertises endpoints from all three schemas (one HEAD or GET per schema returning 200; rows or empty array, both pass).

### Validation

```bash
docker exec uis-provision-host bash -lc \
  'cd /mnt/urbalurbadisk/provision-host/uis/tests && ./run-tests.sh postgrest'
```

All tests pass. User confirms.

---

## Phase 7: Documentation

### Tasks

- [ ] 7.1 In `website/docs/services/integration/postgrest.md`: at lines 77 and 220 (the two `./uis configure postgrest` examples that currently pass `--schema api_v1`), replace `--schema api_v1` with `--schemas api_v1,marts,raw` and update surrounding prose to match. Audit the rest of the page for any other `--schema` references.
- [ ] 7.2 Add a new subsection "Reconfigure semantics": explain wipe-and-rewrite, the deterministic-end-state contract, and the order-significance note (first schema is PostgREST's default schema served when `Accept-Profile` is omitted).
- [ ] 7.3 Add a new subsection "Inspecting the current schema list" with the kubectl one-liner: `kubectl get secret <app>-postgrest -n postgrest -o jsonpath='{.data.PGRST_DB_SCHEMAS}' | base64 -d`.
- [ ] 7.4 Add a "UIS-managed role contract" callout: *"`<app>_web_anon` grants are exclusively UIS-managed. Manual `GRANT … TO <app>_web_anon` will be lost on the next configure."*
- [ ] 7.5 Add a "Upgrading from PLAN-002 single-schema" subsection: *"Run `./uis configure postgrest --app <app> --schemas <list>` once to populate the new `PGRST_DB_SCHEMAS` secret key before any rotate. Roles persist; the existing `PGRST_DB_URI` (and therefore the password) is preserved; grants are reset to match `<list>` exactly via the wipe-and-rewrite path. If `<list>` includes `api_v1` (the PLAN-002 default), the resulting grants on `api_v1` are functionally identical to before."*

### Validation

```bash
# Build docs locally if a local docs server is available; otherwise rely on CI's
# "Generate UIS Documentation" + "Deploy Documentation" workflows.
cd website && npm run build
```

User confirms `postgrest.md` renders correctly and the new subsections read cleanly.

---

## Phase 8: End-to-end smoke against atlas's use case

This phase is run by the **tester**, via a `talk*.md` brief in `/Users/terje.christensen/learn/helpers/testing/uis1/talk/`. The contributor writes the brief; tester executes; contributor reviews results.

### Tasks

- [ ] 8.1 Contributor: build local image (`./uis build`) and write the test brief.
- [ ] 8.2 Tester: ensure atlas's database exists. Run `UIS_IMAGE=uis-provision-host:local ./uis configure postgresql --app atlas --database atlas_db --json` — idempotent; runs once if the cluster has been reset since this plan was written, no-op otherwise.
- [ ] 8.3 Tester: run `UIS_IMAGE=uis-provision-host:local ./uis configure postgrest --app atlas --database atlas_db --schemas api_v1,marts,raw --url-prefix api-atlas`. Assert clean exit with JSON listing all three schemas.
- [ ] 8.4 Tester: run `UIS_IMAGE=uis-provision-host:local ./uis deploy postgrest --app atlas --url-prefix api-atlas`. Assert clean PLAY RECAP and pod readiness.
- [ ] 8.5 Tester: `curl -fsS http://api-atlas.localhost/` returns OpenAPI advertising endpoints from all three schemas. Spot-check one endpoint per schema returns 200 (rows or empty array, both pass — `marts.*` / `raw.*` may be empty in the tester's environment if dbt/ingest hasn't run).
- [ ] 8.6 Tester: re-run configure with `--schemas api_v1,marts` (drop `raw`). Assert OpenAPI no longer advertises `raw.*`. Assert `pg_default_acl` cleared for `raw`:
  ```sql
  SELECT count(*) = 0 FROM pg_default_acl
   WHERE defaclnamespace = (SELECT oid FROM pg_namespace WHERE nspname='raw')
     AND defaclacl::text LIKE '%atlas_web_anon%';
  ```
- [ ] 8.7 Tester: re-run configure with `--schemas api_v1,marts,raw` (restore). Assert restoration.
- [ ] 8.8 Contributor: open PR, ensure CI green (Build UIS Container, Test UIS Scripts, Generate UIS Documentation, Deploy Documentation), merge.
- [ ] 8.9 Surface the rebuilt-image SHA to the user (contributor) once CI publishes it. The user owns cross-repo communication with atlas — they decide when/whether to update `atlas/website/docs/ai-developer/plans/talk/talk.md`. Claude does not proactively write to the atlas talk thread.

### Validation

User (contributor) confirms tester results, CI green, merge complete, atlas pinged.

---

## Acceptance Criteria

- [ ] `./uis configure postgrest --app <app> --schemas <list>` accepts comma-separated lists and runs the normalize/validate pipeline (R4) before any SQL.
- [ ] First-time configure creates roles + grants + secret (with both `PGRST_DB_URI` and `PGRST_DB_SCHEMAS`) atomically.
- [ ] Reconfigure with a different list wipes prior grants (including `pg_default_acl` entries for dropped schemas) and re-applies the new list, in one transaction.
- [ ] No-op short-circuit fires only when both roles + secret exist AND `PGRST_DB_SCHEMAS` exact-string-matches the normalized incoming list.
- [ ] `--rotate` preserves `PGRST_DB_SCHEMAS`; errors loudly when the key is absent.
- [ ] `--purge` clears both keys (no change required; verify only).
- [ ] Deploy CLI no longer accepts `--schema` or `--schemas`; deploy template reads `PGRST_DB_SCHEMAS` via `valueFrom.secretKeyRef`.
- [ ] `<app>_authenticator → <app>_web_anon` membership survives `DROP OWNED BY` (covered by test 6.8).
- [ ] `postgrest.md` documents `--schemas`, the wipe-and-rewrite contract, the kubectl listing one-liner, the order-significance note, the UIS-managed-role invariant, and the PLAN-002-upgrade note.
- [ ] CI workflows green; rebuilt `uis-provision-host:latest` published to GHCR; SHA reported to the user (cross-repo comms with atlas are user-driven, not Claude-driven).

---

## Files to Modify

- `provision-host/uis/lib/configure-postgrest.sh` — normalize/validate helper, no-op short-circuit, role-state detection, three-way path (first-time / reconfigure-with-secret / reconfigure-without-secret), wipe-and-rewrite SQL, secret-with-schemas write, NOTIFY, rotate-preserves-key, error-message updates.
- `provision-host/uis/lib/configure.sh` — replace `--schema` with `--schemas` in argument parsing; rename internal variable `schema` → `schemas`.
- `provision-host/uis/manage/uis-cli.sh` — replace `--schema` with `--schemas` on the configure path; remove both `--schema` and `--schemas` from the deploy path.
- `provision-host/uis/services/integration/service-postgrest.sh` — example commands.
- `ansible/playbooks/templates/088-postgrest-config.yml.j2` — `PGRST_DB_SCHEMAS` via `valueFrom.secretKeyRef`.
- `ansible/playbooks/088-setup-postgrest.yml` — drop `_schema` extra-var assertion + debug-line reference.
- `provision-host/uis/tests/unit/test-configure-postgrest-schemas.sh` — new (Phase 6.1).
- `provision-host/uis/tests/deploy/test-configure-postgrest-schemas-integration.sh` — new (Phase 6.2 onward).
- `website/docs/services/integration/postgrest.md` — Phase 7 content.

---

## Implementation Notes

- **SQL identifier safety**: the existing handler bash-substitutes `$schema` directly into SQL (`configure-postgrest.sh:400`). The R4 regex (`^[a-zA-Z_][a-zA-Z0-9_]*$`) is the SQL-injection guard — Phase 1 task 1.3 (the normalizer) must reject before any string interpolation. Do not skip the regex even though Atlas's identifiers are clean today.
- **Transaction wrapping**: the current handler runs CREATE ROLE inside a DO block, then grants outside it. With `--set ON_ERROR_STOP=on` each top-level statement is its own implicit transaction. Phase 2 task 2.5 must wrap the whole SQL block in explicit `BEGIN; … COMMIT;` so a per-schema GRANT failure rolls back the role creation. Pre-validation (task 2.3, exercised by test 6.7) covers the primary failure mode (missing schema named in `--schemas`); the transaction wrapping is defense-in-depth against a schema being dropped by another process between pre-validation and the GRANT — race-condition territory, not directly exercised by tests.
- **`DROP OWNED BY` scope**: per-database, drops objects owned by + revokes privileges granted to the role. Run inside the per-app database (the `_pgrst_exec_db` pattern already does this). Does NOT touch cluster-level role memberships — `<app>_authenticator → <app>_web_anon` survives. Test 6.8 verifies.
- **Secret rewrite atomicity**: `kubectl create secret … --dry-run=client -o yaml | kubectl apply` replaces the entire secret. Read existing keys first; rewrite both. Don't drop `PGRST_DB_URI` accidentally during a `--rotate` or schema-only reconfigure.
- **NOTIFY scope**: `NOTIFY pgrst, 'reload schema'` runs against the per-app database. PostgREST's `db-channel` defaults to `pgrst` on the database the connection string points at. No special config needed.
- **`--schema` is gone, not aliased**: any operator passing `--schema` gets a standard "Unknown option" error from the CLI parser. Atlas's setup.md updates to `--schemas` per atlas Message 3; UIS-internal docs are rewritten in this PR.

---

## Out of Scope

- Authenticated schemas / role-pairs (Atlas's `private_marts` / `private_raw`) — PLAN-003 territory.
- Per-table grant control — `--schemas` is schema-granularity only.
- Per-instance `./uis status` reporting (Decision #19 from `INVESTIGATE-postgrest.md`) — separate plan.
- Atlas-side `setup.md` updates — Atlas owns those (atlas Message 3).
