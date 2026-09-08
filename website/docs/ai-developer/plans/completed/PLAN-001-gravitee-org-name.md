# PLAN-001: Gravitee organisation name driven by `DEFAULT_ORGANIZATION_NAME`

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed (2026-05-04, Round 7.5 PASS)

**Goal**: Replace Gravitee's chart-default organisation name (`Default organization`) with whatever value is configured in `DEFAULT_ORGANIZATION_NAME`. Default to `UIS Local Dev` for fresh installs. Apply the value at deploy time via a post-`helm-install` `psql UPDATE` against `graviteedb.organizations`. Drop-database test passes — no post-deploy management-API patching.

**Last Updated**: 2026-05-04

**Investigation**: [INVESTIGATE-gravitee-post-deploy-config.md](./INVESTIGATE-gravitee-post-deploy-config.md) — Finding 3.

**Prerequisites**: All resolved as of milestone commit `b7fe659` — every gravitee-config experiment is closed (OQ3, OQ4, OQ5, OQ6, OQ7, OQ9 resolved; OQ1, OQ2, OQ8 demoted/shipped). Chart inspection confirmed no chart value exposes the human-readable organisation name (only the slug ID `DEFAULT`).

**Blocks**: PLAN-002-gravitee-db-baked-urls (next plan, Findings 2 + 4-api-side) — same general lever family (kubectl exec psql), so PLAN-001 ships first to prove the pattern.

---

## Problem

`./uis deploy gravitee` on a fresh DB ends with `curl /management/organizations/DEFAULT | jq '.name'` returning `"Default organization"` — Liquibase's seed value. The Gravitee Console surfaces this in the top nav and Organization Settings; the placeholder is visible to every user. Maintainer wants it set to a UIS-controlled label, configurable via the same `DEFAULT_*` system-wide-knob pattern Authentik tenants / Grafana orgs / Backstage `app.title` will eventually adopt.

## Solution

Three-layer plumbing matching the existing `DEFAULT_ADMIN_EMAIL` → `GRAVITEE_ADMIN_EMAIL` flow:

1. **Layer 1** (`provision-host/uis/templates/default-secrets.env`): new `DEFAULT_ORGANIZATION_NAME=UIS Local Dev`. Image-shipped default.
2. **Layer 2a** (`provision-host/uis/templates/secrets-templates/00-common-values.env.template`): new `DEFAULT_ORGANIZATION_NAME=PlaceholderOrgName` line. Gets sed-overwritten at first init by `copy_secrets_templates()` in `first-run.sh:282-291`.
3. **Layer 2b** (`provision-host/uis/lib/first-run.sh:copy_secrets_templates`): new sed line `s/DEFAULT_ORGANIZATION_NAME=.*/DEFAULT_ORGANIZATION_NAME=${DEFAULT_ORGANIZATION_NAME}/`.
4. **Layer 2c** (`provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template` gravitee block): new line `GRAVITEE_ORG_NAME: "${DEFAULT_ORGANIZATION_NAME}"` after `GRAVITEE_ADMIN_PASSWORD`.
5. **Layer 3** (`ansible/playbooks/090-setup-gravitee.yml`): new task after the existing wait-for-ready (task 26) that:
   - Reads `GRAVITEE_ORG_NAME` from `gravitee/urbalurba-secrets`.
   - Reads `PGPASSWORD` from `default/urbalurba-secrets` (already used in the remove playbook).
   - Runs `kubectl exec` into the `postgresql-0` pod with a `psql -c "UPDATE organizations SET name = '<name>' WHERE id = 'DEFAULT';"` command.
   - Logged `changed_when: true`; safe to re-run on every deploy (UPDATE always sets the configured value).

The lever runs after Liquibase has seeded the row (api pod is Ready means Spring context started, which means Liquibase migrations have completed — Spring Boot blocks app startup until Liquibase finishes by default).

### Why kubectl exec psql UPDATE, not the other levers

- ~~Chart value~~ — confirmed no chart knob for the human-readable org name (only the slug `DEFAULT`).
- ~~`--set-string`~~ — needs a chart value.
- ~~Chart `extraInitContainers`~~ — chart doesn't expose it (OQ3).
- ~~Custom Liquibase changeset~~ — workable but adds chart-upgrade fragility (changesets must be ordered/numbered correctly relative to upstream changes).
- ~~Post-deploy management-API PUT~~ — explicitly rejected by INVESTIGATE design constraint.
- **kubectl exec psql UPDATE** — chosen. No chart-rendered manifest changes. Idempotent. Pattern already used in `090-remove-gravitee.yml` tasks 11-12 (DROP DATABASE/DROP ROLE) for purge mode, so the surface area is familiar.

---

## Phase 1: Variable plumbing + lever wiring

### Tasks

- [x] 1.1 Add `DEFAULT_ORGANIZATION_NAME=UIS Local Dev` to `provision-host/uis/templates/default-secrets.env`. Add a one-line comment grouping it with the other `DEFAULT_*` system-wide knobs.
- [x] 1.2 Add `DEFAULT_ORGANIZATION_NAME=PlaceholderOrgName` to `provision-host/uis/templates/secrets-templates/00-common-values.env.template` near the other `DEFAULT_*` lines. Comment notes that the value is overwritten on first init by `copy_secrets_templates()`.
- [x] 1.3 Add a sed line for `DEFAULT_ORGANIZATION_NAME` to `provision-host/uis/lib/first-run.sh:copy_secrets_templates` (lines 282-291). Mirrors the existing `DEFAULT_ADMIN_EMAIL` line.
- [x] 1.4 Add `GRAVITEE_ORG_NAME: "${DEFAULT_ORGANIZATION_NAME}"` to `provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template` in the gravitee block, after `GRAVITEE_ADMIN_PASSWORD` (around line 530).
- [x] 1.5 Add a new task to `ansible/playbooks/090-setup-gravitee.yml` after task 26 (the wait-for-ready). Implemented as task 27 — the existing health-check / status tasks renumbered 27→28, 28→29, 29→30, 30→31. The task reads `GRAVITEE_ORG_NAME` from the gravitee secret inline (`kubectl get secret`) and reuses `postgres_password.stdout` (set earlier by task 9) to authenticate to PostgreSQL, then runs `kubectl exec ... bash -c "PGPASSWORD=... psql -d {{ gravitee_db_name }} -c \"UPDATE organizations SET name = '...' WHERE id = 'DEFAULT';\""`. `changed_when: true` + `no_log: true`. Comment block above explains the post-Liquibase-seed timing and the idempotent UPDATE shape.
- [x] 1.6 Run `./uis build`. New image: `d94e4cb0ea3b` (multi-arch). Tester picks up via restart.

### Validation

```bash
./uis exec grep DEFAULT_ORGANIZATION_NAME /mnt/urbalurbadisk/provision-host/uis/templates/default-secrets.env
./uis exec grep GRAVITEE_ORG_NAME /mnt/urbalurbadisk/provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template
./uis exec grep -c 'UPDATE organizations SET name' /mnt/urbalurbadisk/ansible/playbooks/090-setup-gravitee.yml
```

Expected: variable lines present, master-template reference present, exactly 1 `UPDATE organizations` line in the playbook.

---

## Phase 2: Tester verification (UIS tester only — no browser test needed)

### Tasks

- [x] 2.1 Append a Round 7 brief to `talk.md` with restart + manual common-values edit (existing-install gap from `INVESTIGATE-cli-deploy-auto-regen-secrets`) + secrets generate/apply + drop-redeploy + the load-bearing org-name probe + regression checks for OQ4 / OQ5 / autoscaling / admin email.
- [x] 2.2 Round 7 tester report received — five-layer wiring verified end-to-end on the override path. Two findings surfaced: (A) load-bearing quoting bug in image-default — `DEFAULT_ORGANIZATION_NAME=UIS Local Dev` (unquoted) gets truncated to `"UIS"` when `first-run.sh` and `secrets generate` `source` the file, so fresh installs would fail acceptance ("UIS Local Dev" required, would get "UIS"). (B) silent-failure mode in secrets pipeline — bad common-values syntax produces incomplete YAML without surfacing the error; `secrets apply` reports success; deploy UPDATEs the DB to empty string. Finding A is on the critical path for PLAN-001 acceptance; Finding B logged in `INVESTIGATE-cli-deploy-auto-regen-secrets.md` as adjacent silent-failure mode.

## Phase 3: Quoting fix (Round 7 Finding A)

### Tasks

- [x] 3.1 Quote the value in `provision-host/uis/templates/default-secrets.env`: `DEFAULT_ORGANIZATION_NAME="UIS Local Dev"`. Comment block updated to flag the QUOTING REQUIRED rule for any future multi-word default.
- [x] 3.2 Quote the placeholder in `provision-host/uis/templates/secrets-templates/00-common-values.env.template`: `DEFAULT_ORGANIZATION_NAME="PlaceholderOrgName"` (consistency, plus a one-line comment explaining the rationale).
- [x] 3.3 Update the sed line in `first-run.sh:copy_secrets_templates` to emit a quoted value: `s|DEFAULT_ORGANIZATION_NAME=.*|DEFAULT_ORGANIZATION_NAME=\"${DEFAULT_ORGANIZATION_NAME}\"|`. Delimiter changed from `/` to `|` because the replacement now contains literal escaped double quotes; `|` keeps the line readable. The first-run sed sees the value already shell-stripped of source-time quotes, then re-quotes for the persisted per-install file (so subsequent `source` calls survive).
- [x] 3.4 Run `./uis build`. New image: `875c9a5c9231`. Tester picks up via restart.
- [x] 3.5 Append a Round 7.5 brief to `talk.md` asking the tester to confirm: (a) image-default chain works on a clean per-install init (drop their existing override, let first-run repopulate, deploy, verify "UIS Local Dev" surfaces); (b) all Round 7 regressions still hold.
- [x] 3.6 Round 7.5 tester report received — fresh-init path produces `"UIS Local Dev"` end-to-end (full value, no truncation, no empty string), all regressions hold. Tester also noted that `copy_secrets_templates` is triggered lazily by the first secrets-pipeline command after the per-install file goes missing, not by restart itself; observation captured in `INVESTIGATE-cli-deploy-auto-regen-secrets.md` as a third adjacent failure mode.

### Validation

Tester confirms:
- After fresh deploy, `curl /management/organizations/DEFAULT | jq '.name'` returns `"UIS Local Dev"` (or whatever value the per-install common-values has — defaults to `UIS Local Dev`).
- Override probe: tester edits `DEFAULT_ORGANIZATION_NAME=Round7TestOrg` in their per-install common-values, regen + apply + redeploy → API now returns `"Round7TestOrg"`. Proves the variable is wired, not a constant.
- Cluster secret `gravitee/urbalurba-secrets:GRAVITEE_ORG_NAME` matches the value seen in the API response (consistency check).
- Round 6/6.5 changes still work (OQ4 + OQ5 regression: Console at `/`, Portal at `/_portal/`, all assets serve correctly).
- Round 5 still holds: 4 pods, 0 HPAs.

---

## Acceptance Criteria

- [ ] `DEFAULT_ORGANIZATION_NAME=UIS Local Dev` in `default-secrets.env` with comment.
- [ ] `00-common-values.env.template` has the placeholder line that gets sed-overwritten on first init.
- [ ] `first-run.sh:copy_secrets_templates` includes a `DEFAULT_ORGANIZATION_NAME` sed substitution.
- [ ] `00-master-secrets.yml.template` gravitee block has `GRAVITEE_ORG_NAME: "${DEFAULT_ORGANIZATION_NAME}"`.
- [ ] `090-setup-gravitee.yml` has a new task 27 that runs `psql UPDATE organizations SET name = ...` post-Liquibase-seed.
- [ ] Fresh `./uis deploy gravitee` ends with the API returning the configured org name (default: `UIS Local Dev`).
- [ ] Override path confirmed: changing the per-install value and redeploying changes the org name in the API response.
- [ ] No regression on Round 3 OQ4 (Console relative `baseURL`), Round 6/6.5 (Portal sub-path), Round 5 (4 pods 0 HPAs), or admin email (`post@helpers.no` post-fresh-deploy).
- [ ] No post-deploy management-API `PUT/POST/PATCH` calls added.

---

## Files to Modify

- `provision-host/uis/templates/default-secrets.env` — new `DEFAULT_ORGANIZATION_NAME` line.
- `provision-host/uis/templates/secrets-templates/00-common-values.env.template` — new placeholder line.
- `provision-host/uis/lib/first-run.sh` — new sed substitution in `copy_secrets_templates()`.
- `provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template` — new `GRAVITEE_ORG_NAME` line in gravitee block.
- `ansible/playbooks/090-setup-gravitee.yml` — new task 27 (psql UPDATE), existing summary task renumbered.

---

## Implementation Notes

**Why post-`helm-install` (after wait-for-ready), not pre-install or via init container**: Liquibase migrations run on api pod startup. Pre-install (e.g. an init container that seeds the row before the api pod starts) would race with Liquibase's own seed. Post-install with the api pod Ready is the safe window — Spring Boot blocks application startup until Liquibase finishes migrations, so a Ready pod implies migrations are done.

**Why `UPDATE organizations SET name = ... WHERE id = 'DEFAULT'`, not `UPSERT`**: the chart's Liquibase seed always inserts the row. There's no scenario where the row is missing when this task runs (api pod was Ready, which means Liquibase ran). UPDATE is safe and idempotent.

**Why the password from `default/urbalurba-secrets:PGPASSWORD`, not a Gravitee-specific password**: this is the postgres admin password used to authenticate as the postgres superuser, same as the existing remove playbook task 8. The `gravitee_user` role has limited privileges; the superuser needs to do the UPDATE. The password lookup pattern is already established.

**Existing-install workflow gap**: parking `INVESTIGATE-cli-deploy-auto-regen-secrets` covers this. For PLAN-001, the Round 7 brief instructs the tester to manually edit their per-install common-values + regen + apply before deploying. Once `INVESTIGATE-cli-deploy-auto-regen-secrets` lands, this manual step will go away for everyone.

**No separate PR** — folds into the gravitee-config branch per existing maintainer direction.

**Documentation**: comment blocks at each layer explain the cross-references (default-secrets.env → common-values → master template → playbook task). `gravitee.md` Configuration section gets a one-line note that org name is set via `DEFAULT_ORGANIZATION_NAME` and how to override.
