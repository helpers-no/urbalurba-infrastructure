# PLAN-002: Replace DB-baked `portalEntrypoint` placeholder with a relative path

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed (2026-05-05, Round 10 PASS)

**Round 9 lever resolution (2026-05-05)**: after a four-round lever search (Rounds 8 → 8.5 → 8.6 → 9), the actual lever is a post-Liquibase psql `INSERT INTO parameters … ON CONFLICT … DO UPDATE`. The `https://api.company.com` placeholder is a hardcoded fallback in `gravitee-apim-rest-api-model-*.jar` returned when no row exists for the `portal.entrypoint` settings key. Round 9 tester validated live — INSERT a row, API immediately serves the new value, no pod restart. Mirrors PLAN-001 task 27's psql shape exactly.

**Diagnostic trail summary** (full detail in `talk.md` Rounds 8 / 8.5 / 8.6 / 9):

- **Round 8 found**: placeholder is NOT in the DB. `environments` table is 5 varchars; `parameters` had only one unrelated row. Hypothesis: hardcoded Java fallback.
- **Round 8.5 found**: chart-shipped literal-dot env var (`portal.entrypoint`, set by chart helper). New hypothesis: override via env-var.
- **Round 8.5 also showed**: `GRAVITEE_INSTALLATION_API_URL=/` crashes the api pod (URI constructor rejects relative). Finding 4-api-side definitively upstream-bounded.
- **Round 8.6 found**: chart helper at `templates/api/api-deployment.yaml` emits the env var; chart values exposes no `portal.entrypoint` knob; chart has no `forwardHeadersStrategy`. Lever option: append duplicate `portal.entrypoint` to `api.env` for k8s last-wins.
- **Round 9 broke that theory**: POSIX env-name rule (`[A-Z_][A-Z0-9_]*`) means containerd silently filters the literal-dot entry from `execve()`. JVM never sees it. Both chart's entry AND any duplicate are dead code. The chart bug is worth filing upstream.
- **Round 9 found the real lever**: hardcoded Java constant in `gravitee-apim-rest-api-model-*.jar`; INSERT into `parameters` table overrides the fallback. Tester validated live.

**This PLAN now describes the shipped implementation**. Phase sections below are rewritten to match. The historical multi-phase / DEFAULT_*-variable scaffolding from earlier reframes is removed; the actual change is one chart-config edit (remove dead env var) and one playbook task (psql INSERT/ON CONFLICT).



**Goal**: Stop Gravitee from exposing the chart-default placeholder `https://api.company.com` as `portal.entrypoint` in `/management/.../environments/DEFAULT/settings`. Replace with the relative value `/_portal/` (matching the OQ5 / Round 6.5 same-origin Portal consolidation) via a `psql UPDATE` against the gravitee database, applied post-`helm-install` in the existing setup playbook. Drop-database test passes — no post-deploy management-API patching, no UIS-side hostname variable, no redeploy required when adding cloudflared/tailscale.

**Last Updated**: 2026-05-04

**Investigation**: [INVESTIGATE-gravitee-post-deploy-config.md](./INVESTIGATE-gravitee-post-deploy-config.md) — Finding 2.

**Prerequisites**: PLAN-001 shipped (org-name DB UPDATE pattern proven via Round 7 + 7.5; playbook task 27 in `090-setup-gravitee.yml` is the template for PLAN-002's task 28).

**Builds on**: Round 6.5 Portal sub-path consolidation — Console + Portal serve same-origin under `gravitee.<domain>/_portal/` with `Middleware/gravitee-portal-strip` stripping the prefix. A relative `/_portal/` value for `portal_entrypoint` resolves against the requesting page's origin, satisfying Finding 4's "one deploy, any number of hostnames" design constraint.

---

## Scope decisions (set up-front)

**No `DEFAULT_*` variable for the entrypoint value.** Under the Round 6.5 consolidation, the value is `/_portal/` for any install that uses the standard ingress shape. There is no realistic override use case that doesn't also require coordinated changes to `091-gravitee-ingress.yaml` (drop StripPrefix), `manifests/090-gravitee-config.yaml` (drop `PORTAL_BASE_HREF`), and the routing topology. A `DEFAULT_*` knob would invite a per-install edit that produces a non-functional Portal in 100% of cases. The value is a *consequence* of the routing decision, not a configurable knob — so it lives as a hardcoded `_gravitee_portal_entrypoint: "/_portal/"` var in `090-setup-gravitee.yml` with a comment cross-referencing `091-gravitee-ingress.yaml` and the Middleware. Future architectural change to the Portal routing (separate hostname, different sub-path, etc.) updates the playbook var directly. Two lines, no template-pipeline churn.

**Finding 4-api-side framed as "confirm, then accept-with-doc," not "experiment."** OQ6 already established that the api pod constructs outbound absolute URLs (login redirect Location headers, notification email links, webhook payloads) from chart-baked `installation.api.url`, not from request headers. Strong prior that the same code path *also* ignores the DB-baked `portal_entrypoint` for redirect Location construction — same architectural cause, same Vert.x filter chain. Phase 2's 2b probe is structured as **confirmation of the expected failure**, with the resolution being a one-paragraph `gravitee.md` note documenting `gravitee.localhost` as the canonical host for emitted absolute URLs and pointing at an upstream issue for the eventual `X-Forwarded-Host` honour fix. No PLAN-003 needed; no chart `urls[]` array experiment; no further tester rounds for Finding 4-api-side.

If 2b unexpectedly PASSes (i.e., the api pod *does* read the DB column for redirect construction), Finding 4-api-side closes here as a happy bonus. Either outcome ships PLAN-002 in the same tester round.

---

## Phase 1: Implementation (built — image `36b47178012a`)

### Tasks

- [x] 1.1 Edit `manifests/090-gravitee-config.yaml`: remove the dead `portal.entrypoint` env entry added during the Round 8.6 → Round 9 lever-search. Replace its comment block with a forensic breadcrumb explaining *why* not to add it back (POSIX env-name rule + Java model fallback) and pointing readers to talk.md Round 9.
- [x] 1.2 Add `_gravitee_portal_entrypoint: "/_portal/"` to the `vars:` block in `ansible/playbooks/090-setup-gravitee.yml`, with a comment cross-referencing `091-gravitee-ingress.yaml` (StripPrefix middleware) and noting the value is bound to the routing topology, not a per-install knob.
- [x] 1.3 Add new task 28 (`Override portal.entrypoint default in parameters table`) immediately after task 27 (PLAN-001 org-name UPDATE). Body: `kubectl exec` into `postgresql-0` and run `INSERT INTO parameters (key, value, reference_id, reference_type) VALUES ('portal.entrypoint', '{{ _gravitee_portal_entrypoint }}', 'DEFAULT', 'ENVIRONMENT') ON CONFLICT (key, reference_id, reference_type) DO UPDATE SET value = EXCLUDED.value;`. Reuses `postgres_pod_name` + `postgres_password.stdout` + `gravitee_db_name` from the existing PLAN-001 / database-bootstrap tasks. `changed_when: true` + `no_log: true`. Comment block above explains why this is the lever (with talk.md Round 9 cross-reference).
- [x] 1.4 Renumber existing tasks 28→29 (Health-check Management API), 29→30 (Health-check Gateway), 30→31 (Get Gravitee pods), 31→32 (Display final deployment status).
- [x] 1.5 Run `./uis build`. New image: `36b47178012a`.

---

## Phase 2: Tester verification — Round 10

### Tasks

- [x] 2.1 Append a Round 10 brief to `talk.md`: restart with new image, drop & redeploy (purge wipes Round 9's manual INSERT, so this round verifies the playbook actually performs the INSERT), the **2a** load-bearing probe, the **2b** baseline probe (informational — captures the actual `Location:` header for the gravitee.md callout), and full regression suite.
- [x] 2.2 Round 10 tester report received — Step 3 (load-bearing) PASS: API returns `/_portal/` from a clean `--purge`-then-deploy; `parameters` table has exactly one row at ENVIRONMENT scope. Step 4 baseline captured: `Location: http://gravitee.localhost/portal/environments/DEFAULT/auth/console?token=…` regardless of `X-Forwarded-Host`. All Round 3 / 5 / 6 / 6.5 / 7 regressions hold.

### Validation

Tester confirms:
- **2a (load-bearing)** — `curl /management/organizations/DEFAULT/environments/DEFAULT/settings | jq '.portal.entrypoint'` returns `/_portal/`, not `https://api.company.com`.
- **DB confirmation** — `SELECT … FROM parameters WHERE key = 'portal.entrypoint'` returns one row with `value=/_portal/`, `reference_type=ENVIRONMENT`. Confirms the playbook task ran and persisted.
- **2b (baseline, informational)** — login-redirect Location header still echoes `gravitee.localhost` regardless of `X-Forwarded-Host`. Captures the exact wording for the gravitee.md Known-Limitation callout.
- **PLAN-001 regression** — org name still `"UIS Local Dev"`. Two co-existing post-deploy DB writes (UPDATE + INSERT/ON CONFLICT) work correctly together.
- **Round 3 OQ4 / Round 5 / Round 6/6.5 / Round 7 admin email** — all hold.

---

## Phase 3: Documentation pass + close-out

### Tasks

- [x] 3.1 `website/docs/services/integration/gravitee.md`: added "Cross-domain redirects use chart-baked URLs" Known-Limitation callout under Limitations and gotchas, and "Deploy-time DB seed values" subsection under Configuration with a table covering both PLAN-001 (org name UPDATE) and PLAN-002 (portal entrypoint INSERT/ON CONFLICT). Comment cross-references the chart-bug breadcrumb in `manifests/090-gravitee-config.yaml`.
- [x] 3.2 Updated `INVESTIGATE-gravitee-post-deploy-config.md` Status section to "Closed (2026-05-05) — all in-scope findings resolved" with summary of which PLAN closed each Finding.
- [x] 3.3 Moved PLAN-002 to `completed/`.
- [ ] 3.4 Final commit (4th gravitee commit on the unpushed stack: chart-values revert + playbook task 28 + PLAN-002 status + gravitee.md docs + INVESTIGATE status).
- [ ] 3.5 Open the PR for the gravitee-config branch.

---

## Acceptance Criteria

- [x] Dead `portal.entrypoint` env entry removed from `manifests/090-gravitee-config.yaml`; forensic breadcrumb comment in place.
- [x] `_gravitee_portal_entrypoint: "/_portal/"` declared in playbook `vars:` block.
- [x] `090-setup-gravitee.yml` task 28 runs `INSERT INTO parameters … ON CONFLICT … DO UPDATE` post-wait-for-ready; existing health-check/status tasks renumbered 28→29, 29→30, 30→31, 31→32.
- [ ] Round 10 Step 3 PASS — API returns `/_portal/` from a clean `--purge`-then-deploy.
- [ ] Round 10 Step 4 baseline recorded — actual `Location:` header captured for gravitee.md callout.
- [ ] PLAN-001's org-name UPDATE still works post-Round-10 redeploy.
- [ ] No regression on Round 3 OQ4, Round 5, Round 6/6.5, Round 7 admin email.
- [ ] No post-deploy management-API `PUT/POST/PATCH` calls added.
- [ ] No new `DEFAULT_*` variable introduced.
- [ ] `gravitee.md` Configuration note + Finding 4-api-side Known-Limitation callout landed.
- [ ] `INVESTIGATE-gravitee-post-deploy-config.md` Status section updated to "all findings closed."
- [ ] PLAN-002 moved to `completed/`.

---

## Files to Modify

- `manifests/090-gravitee-config.yaml` — remove dead `portal.entrypoint` env entry, replace comment block with forensic breadcrumb. ✅
- `ansible/playbooks/090-setup-gravitee.yml` — new `_gravitee_portal_entrypoint` var, new task 28 (psql INSERT/ON CONFLICT), tasks 28–31 renumbered to 29–32. ✅
- `website/docs/services/integration/gravitee.md` — Configuration note + Known-Limitation callout (Phase 3.1).
- `website/docs/ai-developer/plans/backlog/INVESTIGATE-gravitee-post-deploy-config.md` — Status update (Phase 3.2).
- `website/docs/ai-developer/plans/active/PLAN-002-gravitee-db-baked-urls.md` — moved to `completed/` (Phase 3.3).

---

## Implementation Notes

**Why INSERT/ON CONFLICT, not UPDATE-with-WHERE-id**: the `parameters` table seed is empty for the `portal.entrypoint` key on a fresh DB (which is why the Java model fallback fires). UPDATE alone would be a no-op on a missing row; INSERT alone would fail on the unique constraint after a re-deploy. INSERT … ON CONFLICT … DO UPDATE is the right idempotent shape — works on first deploy and on every subsequent one.

**Why post-wait-for-ready, not pre-install / init container / Liquibase changeset**: same rationale as PLAN-001 task 27. The api pod being Ready means Spring context startup completed, which means Liquibase migrations finished, which means the `parameters` table exists with its expected schema. Earlier in the playbook the table either doesn't exist or has untrustworthy state.

**Why `reference_type='ENVIRONMENT'`, not `'ORGANIZATION'`**: Round 9 tester confirmed empirically that the API model reads `portal.entrypoint` from the ENVIRONMENT-scoped row when serving `/management/.../environments/DEFAULT/settings`. ORGANIZATION-scoped rows are accepted by the schema but aren't read by this code path. Single-row INSERT keeps the lever minimal.

**Why no DEFAULT_* variable**: PLAN-002 explicitly chose against the system-wide pattern (unlike PLAN-001's `DEFAULT_ORGANIZATION_NAME` and Round 5's `DEFAULT_AUTOSCALING`). The value `/_portal/` is bound to the routing topology established by `091-gravitee-ingress.yaml` (StripPrefix middleware on `/_portal`) and `manifests/090-gravitee-config.yaml` (`PORTAL_BASE_HREF=/_portal/`). Changing the value alone produces a non-functional Portal. Future architectural change to the Portal routing updates the playbook var directly. The DEFAULT_* plumbing the Round 9 tester proposed (DEFAULT_PORTAL_ENTRYPOINT → GRAVITEE_PORTAL_ENTRYPOINT → playbook var) is the right shape for genuinely customisable values, not for routing-topology consequences.

**Finding 4-api-side stays accept-with-doc**: Round 8.5 Probe B (`GRAVITEE_INSTALLATION_API_URL=/`) crashed the api pod outright (URI constructor rejects relative). Round 8.6 confirmed the chart has no `forwardHeadersStrategy` knob. The api pod's outbound-URL construction (login redirect Location, notification email links, webhook payloads) reads chart-baked absolute `installation.api.url`; an upstream Gravitee patch is required to honour `X-Forwarded-Host` in Vert.x's filter chain. Phase 3.1's Known-Limitation callout documents this with the Round 10 baseline `Location:` header.

**Upstream chart bug worth filing**: `templates/api/api-deployment.yaml` in chart 4.11.x emits `portal.entrypoint` as a literal-dot env var name. POSIX env-name rules (`[A-Z_][A-Z0-9_]*`) mean containerd silently filters it from `execve()` envp; the JVM never sees it. Either rename to `GRAVITEE_PORTAL_ENTRYPOINT` (Spring's relaxed binding accepts it) or drop entirely (the Java model has the hardcoded fallback covering this case anyway). Out of scope for PLAN-002; worth a one-line GitHub issue when convenient.

**No separate PR** — folds into the gravitee-config branch alongside PLAN-001 and the earlier rounds (purge race, relative baseURL, DEFAULT_AUTOSCALING, Portal sub-path, admin email).
