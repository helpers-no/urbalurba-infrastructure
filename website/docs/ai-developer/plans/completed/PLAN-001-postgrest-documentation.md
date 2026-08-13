# Plan: PostgREST service documentation (consumer validation)

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Completed

**Goal**: Produce the PostgREST service documentation page using the established UIS workflow (metadata in `service-postgrest.sh` → generator stub → hand-augmented sections), then have the Atlas developer review it. Their feedback either unblocks implementation or sends the design back to the investigate.

**Completed**: 2026-04-28
**Last Updated**: 2026-04-28 (all phases done; Atlas feedback incorporated; ready for PLAN-002)

**Investigation**: [INVESTIGATE-postgrest.md](./INVESTIGATE-postgrest.md)

**Prerequisites**: The investigate is complete (22 resolved decisions, no open design questions).

**Blocks**: A future implementation plan (e.g. `PLAN-002-postgrest-implementation.md`) cannot start until Atlas approval lands.

---

## Why docs first

The investigate is internally consistent, but the design has only been reviewed inside UIS. The Atlas developer is the actual consumer. If the `api_v1` view contract is too restrictive, the per-app role naming wrong, or the configure flow doesn't match how Atlas wants to publish data, the cheapest moment to discover that is *before* a single line of platform code is written.

This plan defers all deployment work. The deliverable is one Docusaurus page that someone unfamiliar with the design can read end-to-end and answer either *"yes, this gives me what I need"* or *"no, here's what's missing."*

## How this plan respects the existing docs pipeline

UIS service pages are not hand-written from scratch. They are seeded by `provision-host/uis/manage/uis-docs-markdown.sh` from the metadata fields in `service-<id>.sh`, then hand-augmented in `<!-- MANUAL: ... -->` blocks and additional sections. See [Documentation Standards — Path A: Service pages](../../../contributors/rules/documentation.md) and [CI/CD and Generators §uis-docs-markdown.sh](../../../contributors/guides/ci-cd-and-generators.md#uis-docs-markdownsh--service-documentation-pages).

This plan therefore creates `service-postgrest.sh` with **metadata fields only** (no `SCRIPT_PLAYBOOK`, no actual deployment), runs the generator to produce the stub, and augments it with the substantive content. The service definition becomes "deployable" only when a later plan adds `SCRIPT_PLAYBOOK` and the playbook itself.

---

## Phase 1: Create draft `service-postgrest.sh` (metadata only) — ✅ DONE

### Tasks

- [x] 1.1 Create `provision-host/uis/services/integration/service-postgrest.sh` with the following fields. **Do not** set `SCRIPT_PLAYBOOK` — its absence is what marks this as docs-only. The service will appear in `./uis list` but is not deployable yet. ✓ (verified 2026-04-28; Atlas-feedback editorial fix: changed `platform's` to `the shared` in `SCRIPT_SUMMARY` since the docs generator strips single quotes)
- [x] 1.2 Place the logo at `website/static/img/services/postgrest-logo.svg`. ✓ (icon-only SVG; the upstream PNG was initially used at 1500×500 but replaced with an icon-only SVG post-merge because the PNG includes the wordmark which doesn't fit the service-card layout)

### Validation — ✅ PASS

uis-user1 confirmed via the testing-repo `talk.md` channel Round 1 (2026-04-28):
- Container restarted cleanly with `uis-provision-host:local`
- `./uis list` shows 31 services (was 30); postgrest appears as `INTEGRATION  ❌ Not deployed` — correct (no playbook by design)
- `./uis list | grep postgrest` returns the expected single line

---

## Phase 2: Generate the docs stub — ✅ DONE

### Tasks

- [x] 2.1 Run the markdown generator for postgrest. ✓ (stub generated and committed at `website/docs/services/integration/postgrest.md`)
- [x] 2.2 Verify the file appeared with the expected frame (frontmatter, metadata table, sections). ✓
- [x] 2.3 Verify the page renders with `cd website && npm run build`. ✓ (build SUCCESS, exit 0; postgrest page renders under integration sidebar)

### Validation — ✅ PASS

uis-user1 confirmed via talk.md Round 2 (2026-04-28):
- `./uis docs generate` produces `services.json (31 services)` (was 30)
- The postgrest entry contains all expected metadata fields (id, name, category=INTEGRATION, namespace=postgrest, requires=["postgresql"], checkCommand, logo, website, summary)
- No `playbook` key (intentionally absent per metadata-only design)
- No other service entry changed; alphabetical ID list is intact

Host-side: `cd website && npm run build` returned `[SUCCESS] Generated static files` with only pre-existing broken-link warnings.

**Phase 1 metadata block (kept for reference — what was actually committed to `service-postgrest.sh`):**

```bash
SCRIPT_ID="postgrest"
SCRIPT_NAME="PostgREST"
SCRIPT_DESCRIPTION="Auto-generated REST API from a curated PostgreSQL schema"
SCRIPT_CATEGORY="INTEGRATION"

SCRIPT_REQUIRES="postgresql"
SCRIPT_PRIORITY="50"
SCRIPT_NAMESPACE="postgrest"
SCRIPT_IMAGE="postgrest/postgrest:<version-pinned-during-PLAN-002>"

# Multi-instance — see INVESTIGATE-postgrest.md Decisions #3, #16, #19
# Backstage shape per Decision #9 (deferred until Backstage deploys)
SCRIPT_CONSUMES_APIS="postgresql"
SCRIPT_PROVIDES_APIS=""  # TODO(backstage): emit per-instance <app>-rest entries when Backstage deploys
```

(`SCRIPT_SUMMARY` uses "the shared PostgreSQL service" — the docs generator strips single quotes, so an apostrophe in `platform's` would have been lost in services.json.)

---

## Phase 3: Augment the stub with substantive content — ✅ DONE

PLAN-001 hand-writes the sections that capture what makes PostgREST unusual. The standard frame from the generator does not cover these — they are PostgREST-specific and must be added.

### Tasks

- [x] 3.1 Replace the `<!-- MANUAL: Service-specific configuration details -->` block under "Configuration" with a multi-section explanation covering:
  - **The `api_v1` contract** — what the application *must* do before deploying PostgREST. Worked SQL block: `CREATE SCHEMA api_v1; CREATE VIEW api_v1.kommune AS SELECT … FROM marts.dim_kommune;`. Why a separate schema, not raw tables.
  - **Connection model and role naming** — why the app's owner user (e.g. `my_app`) is *not* what PostgREST connects as. The `<app>_authenticator` LOGIN NOINHERIT role and `<app>_web_anon` NOLOGIN role. Why prefixed (Postgres roles are cluster-wide). What `SET LOCAL ROLE` does per request.
  - **Lifecycle commands** — `./uis configure postgrest --app <name> --database <db> --schema api_v1 --url-prefix api-<name>`, then `./uis deploy postgrest --app <name>`. One-paragraph each: what changes Postgres-side, what changes Kubernetes-side, why configure and deploy are split.
  - **Schema reload** — when the app adds a new view to `api_v1`, what does it run? `NOTIFY pgrst, 'reload schema';` from within Postgres for hot reload, or `kubectl rollout restart deployment/<app>-postgrest` for a clean cycle.
  - **Multi-instance coexistence** — show two apps (atlas + customers) sharing the platform's Postgres without colliding. List the artefacts each owns.
  - **Resulting URLs** — the same single IngressRoute simultaneously answering `http://api-<app>.localhost`, `https://api-<app>.<tailnet>.ts.net`, and `https://api-<app>.<public-domain>`, via `HostRegexp(\`api-<app>\..+\`)`.

- [x] 3.2 Add a new top-level section "Example: Atlas open-data API" *(after Configuration, before Undeploy)* showing the full Atlas walkthrough.
- [x] 3.3 Replace the `<!-- MANUAL: Common issues and solutions -->` block under "Troubleshooting" with at least two real entries.
- [x] 3.4 Add an "Out of scope" section near the bottom.
- [x] 3.5 Rebuild the docs site. ✓ (`npm run build` returned `[SUCCESS]`)

### Validation — ✅ PASS

`cd website && npm run build` succeeds with exit 0; `[SUCCESS] Generated static files in "build"`. The augmented `postgrest.md` includes all six required subsections (api_v1 contract, connection model, lifecycle, schema reload, multi-instance, resulting URLs), the Atlas worked example, two real Troubleshooting entries, and an Out-of-scope section. Two extra subsections were added during Phase 4 below: "Embedded resources require real FK constraints" and "Column descriptions don't propagate to wrapper views" (both responsive to Atlas verification feedback).

---

## Phase 4: Atlas developer review — ✅ DONE (Outcome: 🔁 Feedback recorded and incorporated)

### Tasks

- [x] 4.1 Share the rendered docs page with the Atlas developer. ✓
- [x] 4.2 Ask the explicit question: *"Reading this page, can you publish Atlas's data via PostgREST as described?"* ✓
- [x] 4.3 Capture feedback and sort into buckets. ✓ — Atlas verification feedback received 2026-04-29. Atlas ran four pre-flight experiments against PostgREST 14.10 + UIS PostgreSQL 16.6 and surfaced findings across all three buckets:

  **Bucket (a) — editorial:** `SCRIPT_SUMMARY` apostrophe stripped by docs generator. Fixed in `service-postgrest.sh` (changed `platform's` to `the shared`).

  **Bucket (b) — documentation gap:** Two real gaps in `website/docs/services/integration/postgrest.md` set wrong expectations for consumers:
  - **FK embeds need actual `FOREIGN KEY` constraints** — `?select=*,kommune(*)` only works when the underlying tables have FK constraints; `@source`/`@references` comment hints don't synthesise them. Added subsection "Embedded resources require real FK constraints" with the three workarounds (FK constraints in dbt, computed relationships, skip embeds).
  - **Column descriptions don't propagate from underlying tables to wrapper views.** Added subsection explaining the consumer must re-emit `COMMENT ON COLUMN api_v1.*.col` if descriptions are wanted in the OpenAPI output.

  **Bucket (c) — design gap:** `ALTER DEFAULT PRIVILEGES IN SCHEMA api_v1 GRANT SELECT ON TABLES TO <app>_web_anon;` is missing from the role-creation SQL in [INVESTIGATE-postgrest.md](./INVESTIGATE-postgrest.md) §"What configure generates". Without it, views added to `api_v1` after configure runs are silently invisible to anonymous requests (PostgREST sees them via schema-reload but `<app>_web_anon` has no `SELECT` privilege on the new objects). Recorded as **Addendum 2026-04-29** at the top of INVESTIGATE-postgrest.md and folded into [PLAN-002-postgrest-deployment.md](./PLAN-002-postgrest-deployment.md) Phase 2.4 SQL block. Existing decisions are unchanged per the addendum protocol.

### Validation — ✅ PASS

🔁 **Feedback recorded and incorporated.** All three of Atlas's actionable findings are addressed in the source artefacts: editorial fix in `service-postgrest.sh`; two new doc subsections in `postgrest.md`; one addendum at the top of `INVESTIGATE-postgrest.md` plus a one-line SQL fix in `PLAN-002-postgrest-deployment.md`. The plan is ready for the user-driven completion ceremony (review the changes, then move to `completed/`); Atlas can re-review the changes after merge if they want to confirm the addendum text matches their intent — the implementation in PLAN-002 is the next gate where their feedback bites.

---

## Acceptance Criteria

- [ ] `provision-host/uis/services/integration/service-postgrest.sh` exists with metadata fields populated; `SCRIPT_PLAYBOOK` is intentionally absent
- [x] `website/static/img/services/postgrest-logo.svg` exists (icon-only)
- [ ] Running `bash provision-host/uis/manage/uis-docs-markdown.sh --service postgrest` produces the expected stub
- [ ] `website/docs/services/integration/postgrest.md` is augmented with the api_v1 contract, connection model, lifecycle, schema reload, multi-instance coexistence, the Atlas worked example, and a real Troubleshooting section
- [ ] `cd website && npm run build` succeeds with the new page in the integration sidebar
- [ ] The Atlas developer has read the page and either approved the design or recorded specific changes

---

## Files to Modify

- `provision-host/uis/services/integration/service-postgrest.sh` *(new — metadata only)*
- `website/static/img/services/postgrest-logo.svg` *(new — icon-only SVG; replaced the initially-committed wordmark PNG)*
- `website/docs/services/integration/postgrest.md` *(generated, then hand-augmented)*
- `website/src/data/services.json` *(regenerated by `./uis docs generate` — auto, do not hand-edit)*
- `INVESTIGATE-postgrest.md` *(only if Phase 4 surfaces a design gap, as an addendum)*

**Not touched:** `manifests/`, `ansible/playbooks/`, `provision-host/uis/lib/configure*.sh`, `provision-host/uis/manage/uis-cli.sh`, `secrets-templates/`. Those are the next plan's deliverables.

---

## Out of scope

- All deployment work (manifests, configure handler, playbooks, CLI dispatch). Belongs in the implementation plan, written after Atlas approval.
- The verify playbook (`088-test-postgrest.yml`).
- JWT/Authentik integration.
- Wider improvements to the docs pipeline. The known gap that `<!-- MANUAL: ... -->` markers do not protect content during `--force` regeneration is tracked in [INVESTIGATE-docs-markdown-update-logic.md](../backlog/INVESTIGATE-docs-markdown-update-logic.md); this plan does not address it. We rely on skip-if-exists for protection.

---

## What success looks like

The Atlas developer reads the docs page, runs through the Atlas worked example mentally, and says: *"Yes — if I write the `api_v1` views in atlas-data-repo and you give me `./uis configure postgrest --app atlas …`, I have a public REST API."*

If they say that, the implementation plan can be written with confidence that the design fits a real consumer. If they don't, the cost of revision is one docs page and one investigate addendum — no rolled-back manifests, no half-built handler, no broken playbook.
