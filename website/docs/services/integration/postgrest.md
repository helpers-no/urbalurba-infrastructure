---
title: PostgREST
sidebar_label: PostgREST
---

# PostgREST

Auto-generated REST API from a curated PostgreSQL schema.

| | |
|---|---|
| **Category** | Integration |
| **Deploy** | `./uis deploy postgrest --app <name>` (per-instance) |
| **Undeploy** | `./uis undeploy postgrest --app <name>` |
| **Depends on** | postgresql |
| **Required by** | None |
| **Image** | `postgrest/postgrest:v14.10` |
| **Default namespace** | `postgrest` |

## What It Does

PostgREST is a single Haskell binary that introspects a PostgreSQL schema and exposes its tables and views as REST endpoints, with foreign keys becoming embedded-resource relations and OpenAPI metadata served at `GET /`. PostgREST 14.x (the version UIS currently pins, `v14.10`) emits Swagger 2.0; v15+ may upgrade to OpenAPI 3.x. UIS deploys one PostgREST instance per consuming application, all sharing a single namespace and the platform's PostgreSQL service. Each instance is configured separately via `./uis configure postgrest --app <name>`.

## Configuration

PostgREST is a multi-instance service: one Deployment per consuming application, configured independently. Before deploying you must answer four questions: which app, which database, which schema, and what URL prefix.

### The `api_v1` contract (application-side, required)

PostgREST must point at a curated `api_v1` schema of views — never at raw application tables. The application owns this schema; UIS does not write it for you. Minimum setup, run once against your application's database:

```sql
CREATE SCHEMA api_v1;

-- Curated views over your internal model. Hide debug columns,
-- expose only what you want as a public API.
CREATE VIEW api_v1.kommune AS
  SELECT kommune_nr, name, fylke_nr, population_latest
  FROM marts.dim_kommune;
```

Why this rule:

- **Decouples the API contract from internal models** — refactor your tables without breaking clients.
- **Column-level control** — internal-only columns (raw scrape timestamps, debug fields) stay in `marts.*` and never reach the API.
- **Versioning** — when v2 lands, create `api_v2` alongside; deprecate `api_v1` on a schedule, no client breakage.
- **Per-endpoint Row-Level Security** later — RLS policies attach to views, not raw tables.

### Connection model and role naming

PostgREST does **not** connect as your application's owner user (e.g. `my_app`). It uses a separate role pair, created by `./uis configure postgrest`:

- `<app>_authenticator` — `LOGIN`, `NOINHERIT`, with a generated password. The role PostgREST connects as. `NOINHERIT` is load-bearing: it has no implicit privileges; only what `SET LOCAL ROLE` explicitly switches to is granted.
- `<app>_web_anon` — `NOLOGIN`. The role for unauthenticated requests. Has `SELECT` on `api_v1`.

Per request, PostgREST connects as `<app>_authenticator`, runs `SET LOCAL ROLE <app>_web_anon`, executes the query in that role's permissions, then resets at end of request. Your application's existing user and password are untouched.

The `<app>_` prefix is required because Postgres roles are cluster-wide. Two apps with unprefixed `web_anon` would collide on the platform's shared PostgreSQL.

### Lifecycle commands

```bash
# 0. Bootstrap the application's database (one-time, per app)
#    Creates <app>_db + the <app> Postgres role with credentials, and
#    auto-exposes the cluster's postgresql service at localhost:35432.
#    Run before the application's data pipeline so that api_v1.* views
#    exist on the database by the time configure-postgrest runs in step 1.
./uis configure postgresql --app atlas --database atlas_db --json
#    → Copy the credentials from the JSON output into the application's
#      env (DATABASE_URL, PGUSER, PGPASSWORD, PGDATABASE), then run the
#      application's data pipeline (migrations and any data loading) so
#      that the api_v1.* views are populated before step 1 runs.

# 1. Configure PostgREST (Postgres-side role pair + Secret in postgrest namespace)
./uis configure postgrest --app atlas \
    --database atlas_db \
    --schemas api_v1,marts,raw \
    --url-prefix api-atlas
#    `--schemas` is a comma-separated list — pass one or many. The list is
#    stored on the per-app secret (key PGRST_DB_SCHEMAS) and consumed by
#    deploy automatically; deploy itself takes no schema flags.

# 2. Deploy (Kubernetes objects: Deployment, Service, IngressRoute)
./uis deploy postgrest --app atlas

# 3. Verify (see [Smoke checks](#smoke-checks) below for the full template)
curl http://api-atlas.localhost/             # Swagger 2.0 metadata
curl http://api-atlas.localhost/kommune      # Sample view
```

Step 0 is required before step 1. `./uis configure postgrest` runs a precheck that the named database exists in the cluster's PostgreSQL — if it doesn't, configure aborts with a clear error and creates no side effects (no roles, no Secret). Running step 0 first is what guarantees the precheck passes; it also gives the application a role + credentials to write `marts.*` and `api_v1.*` into. Step 0 is per-app and idempotent.

What changes at each step:

- **`configure postgresql`** (step 0) creates `<app>_db`, the `<app>` Postgres role with a generated password, grants the role on the database, and auto-exposes the cluster service at `localhost:35432`. Returns connection JSON (no credentials are printed elsewhere — the JSON is the only output that carries the password). Use `--rotate` to refresh the password.
- **`configure postgrest`** (step 1) creates the role pair (`atlas_web_anon`, `atlas_authenticator`) and writes the `atlas-postgrest` Secret with both `PGRST_DB_URI` and `PGRST_DB_SCHEMAS` keys. The handler dispatches on the cluster's current state — see [Reconfigure semantics](#reconfigure-semantics) for the full contract. Re-running with the **same** `--schemas` is a no-op; with a **different** list it wipes-and-rewrites grants to match. If the secret was deleted manually, configure recovers by rotating the password (Reconfigure-fresh-password). If exactly one of the two roles exists, the handler refuses to act and tells you to `--purge` (the cluster is in an inconsistent state that UIS won't auto-recover from). Use `--rotate` to force a new password and update the Secret without changing schemas.
- **`deploy`** (step 2) renders per-instance manifests and applies the Deployment, Service, and IngressRoute. Errors out if the instance has not been configured.
- **`undeploy`** removes only the Kubernetes objects. Postgres roles and the Secret remain, so a follow-up `deploy` works without re-configure.
- **`configure postgrest --purge`** drops the Postgres roles and removes the Secret. Pass `--database <app>_db` explicitly — without it, purge falls back to `<app>` as the default database name and aborts with "FATAL: database does not exist" (see [Troubleshooting](#troubleshooting)). Use after `undeploy` for a full teardown.

### Smoke checks

Five canonical checks verify a per-app PostgREST instance is healthy after deploy. Run these from the host machine after step 2:

```bash
# 1. Spec served, version pinned (default schema = first in --schemas)
curl -sS http://api-<app>.localhost/ | jq '{swagger, version: .info.version}'
# expect: {"swagger":"2.0","version":"14.10"}

# 2. Real data flowing through a curated view (default schema)
curl -sS http://api-<app>.localhost/<view-name> | jq 'length'
# expect: > 0

# 3. Each schema in --schemas is reachable via Accept-Profile
#    PostgREST exposes one schema per request; the first schema in
#    PGRST_DB_SCHEMAS is the default (no header needed). Switch to a
#    non-default schema by setting Accept-Profile per request.
for profile in api_v1 marts raw; do
    paths=$(curl -sS -H "Accept-Profile: $profile" http://api-<app>.localhost/ | jq '.paths | length')
    echo "  $profile -> $paths paths"
done
# expect: each schema reports a non-zero path count matching the table
# count for that schema (one row per /table-or-view + 1 for the root /).

# 4. Hidden objects stay hidden (e.g. private_marts not in --schemas)
curl -sS -o /dev/null -w '%{http_code}\n' \
    -H 'Accept-Profile: private_marts' http://api-<app>.localhost/
# expect: 404 (the schema isn't in PGRST_DB_SCHEMAS, so PostgREST refuses
# to switch to it).

# 5. CORS preflight works for browser callers
curl -sS -X OPTIONS \
    -H 'Origin: https://<your-frontend-host>' \
    -H 'Access-Control-Request-Method: GET' \
    http://api-<app>.localhost/<view-name> -i | grep -i access-control
# expect: Access-Control-Allow-Origin: ...
```

### Proving the write-refusal check can actually fail

`./uis verify postgrest --app <name>` asserts that a write through the API is
**refused**. That is a security property, so it is worth knowing it can fail —
and the obvious way to try it silently does nothing:

```sql
-- ✗ does NOT falsify anything
GRANT INSERT ON ALL TABLES IN SCHEMA api_v1 TO web_anon;
```

Two reasons: the role is per-app (`<app>_web_anon`, never a bare `web_anon` —
see [Connection model and role naming](#connection-model-and-role-naming) above), and `ON ALL TABLES` covers only tables that exist
**at grant time**, while the verify creates its probe table during the run.

```sql
-- ✓ actually loosens the instance
ALTER DEFAULT PRIVILEGES IN SCHEMA api_v1
  GRANT INSERT ON TABLES TO atlas_web_anon;
```

The verify then fails, reporting that an unauthenticated write endpoint is live.
Revert with the matching `REVOKE`, or re-run `uis configure postgrest --app
<name>`, which rebuilds the grants from scratch.

Check 1 confirms PostgREST is alive and the pinned image is what's actually running. Check 2 confirms the default schema (the first one in `--schemas`) is reachable and populated. Check 3 is the **multi-schema verification**: it walks the full `--schemas` list, fetching the OpenAPI spec under each `Accept-Profile` and asserting each schema has a non-zero path count. **Don't skip this check on a multi-schema instance** — without `Accept-Profile`, root-path probes only verify the *default* schema, which masks broken GRANTs on the other schemas. Check 4 confirms `private_*` schemas (or anything else not in `--schemas`) return 404 even when explicitly requested. Check 5 confirms CORS is open enough for browser apps.

### Schema reload

When you add a new view to `api_v1`, PostgREST does not see it until its schema cache is invalidated:

```sql
-- Hot reload, no downtime: signal from any psql session against the database
NOTIFY pgrst, 'reload schema';
```

Or restart the pods for a clean cycle:

```bash
kubectl rollout restart deployment/<app>-postgrest -n postgrest
```

`./uis configure postgrest` automatically issues the NOTIFY at the end of any non-no-op run, so a freshly-configured instance picks up new tables without manual intervention. The kubectl rollout is only needed if you change the **order** of `--schemas` (PostgREST re-parses the env var only at startup; the first schema in the list is the default served when `Accept-Profile` is omitted).

### Reconfigure semantics

`./uis configure postgrest --app <app> --schemas <list>` is the only way to change the schema set served by an instance. The handler is **wipe-and-rewrite**:

1. The list passed via `--schemas` is the complete, ordered set of schemas the instance will expose.
2. Each non-no-op call drops every grant the `<app>_web_anon` role currently holds in the database (`DROP OWNED BY`), then re-applies `GRANT USAGE` / `GRANT SELECT ON ALL TABLES` / `ALTER DEFAULT PRIVILEGES` for each schema in `--schemas`. All inside a single transaction.
3. A re-run with the **identical** list (string-equal to the value stored on the secret, order included) is a no-op short-circuit — no SQL fires, no secret is rewritten.
4. A re-run with a **different** list (added schemas, removed schemas, or just reordered) is a regular reconfigure: the wipe-and-rewrite produces an end state that matches `--schemas` exactly. There's no diff state to manage; the new state is fully determined by the flag value.

This keeps the operator-visible contract simple: *the role's grants are exactly `--schemas`, no more, no less.* No accumulated drift across reconfigures, no stealth `pg_default_acl` entries from removed schemas, no need to track what was previously granted.

The trade-off: any out-of-band `GRANT … TO <app>_web_anon` (e.g., a manual GRANT done from `psql` for debugging) will be wiped on the next configure. See [UIS-managed role contract](#uis-managed-role-contract) below.

### Inspecting the current schema list

The schema list lives on the per-app secret as the `PGRST_DB_SCHEMAS` key. Read it with one kubectl line:

```bash
kubectl get secret <app>-postgrest -n postgrest \
    -o jsonpath='{.data.PGRST_DB_SCHEMAS}' | base64 -d
```

The deploy template reads from this same key via `valueFrom.secretKeyRef`, so what kubectl prints is exactly what PostgREST sees on its next pod startup. (Live PostgREST may be running with a stale value if you reconfigured but haven't rolled out a new pod — `kubectl rollout restart deployment/<app>-postgrest -n postgrest` to refresh.)

### UIS-managed role contract

The `<app>_web_anon` role's privileges are **exclusively UIS-managed**. `./uis configure postgrest --app <app>` is the single source of truth: it wipes and re-applies grants based on `--schemas`. Any manual `GRANT … TO <app>_web_anon` will be lost on the next configure.

If you need an extra grant for debugging or one-off access, prefer:
- A separate Postgres role (not the UIS-managed pair).
- An ad-hoc psql session as the `postgres` superuser, scoped to a specific query.

Don't extend the anon role's reach by hand — the configure handler will undo it.

### Upgrading from PLAN-002 single-schema

PLAN-002 shipped a single-schema configure handler with a `--schema` flag. The current multi-schema handler (PLAN-XXX) replaces that with `--schemas` and stores the list on the per-app secret as a new `PGRST_DB_SCHEMAS` key.

If you have a per-app PostgREST instance configured under PLAN-002, the secret has only `PGRST_DB_URI` (no `PGRST_DB_SCHEMAS`). Upgrade in one step:

```bash
./uis configure postgrest --app <app> --database <app>_db --schemas <list>
```

This takes the **Reconfigure-preserve-URI** path:
- The existing `PGRST_DB_URI` is preserved verbatim — password unchanged, no restart needed for credentials.
- Grants are reset to match `<list>` exactly via `DROP OWNED BY` + per-schema GRANTs.
- The new `PGRST_DB_SCHEMAS` key is added to the secret.

If `<list>` includes `api_v1` (the PLAN-002 default), the resulting grants on `api_v1` are functionally identical to before. Other schemas in `<list>` get the same `USAGE` + `SELECT` + `DEFAULT PRIVILEGES` treatment.

`--rotate` requires `PGRST_DB_SCHEMAS` to be present on the secret — running it on a PLAN-002-era secret without first running configure with `--schemas` will fail loudly with an explicit "run configure first" error. This is deliberate: rotate is not the upgrade path.

### Multi-instance coexistence

After configuring two apps, the `postgrest` namespace contains:

```
postgrest/
├── atlas-postgrest         (Deployment, Service, IngressRoute, Secret)
│     → Postgres roles: atlas_web_anon, atlas_authenticator
│     → matches HostRegexp(`api-atlas\..+`)
└── customers-postgrest     (Deployment, Service, IngressRoute, Secret)
      → Postgres roles: customers_web_anon, customers_authenticator
      → matches HostRegexp(`api-customers\..+`)
```

No shared state between instances. Independent deploy / undeploy / configure cycles per app.

### Resulting URLs

A single IngressRoute per instance answers every domain Traefik knows, via `HostRegexp` (see [Ingress and Traefik Rules](../../contributors/rules/ingress-traefik.md)):

| Environment | URL |
|---|---|
| Local dev (Rancher Desktop) | `http://api-atlas.localhost` |
| Tailscale tunnel | `https://api-atlas.<tailnet>.ts.net` |
| Cloudflare tunnel | `https://api-atlas.<your-public-domain>` |

No per-domain configuration in PostgREST or its IngressRoute.

## Limitations and gotchas

### Embedded resources require real FK constraints

The `?select=*,kommune(*)` embed pattern relies on PostgREST reading `pg_constraint` for actual `FOREIGN KEY` constraints on the underlying tables. PostgREST's `@source` and `@references` comment hints are *navigation aids* that point at existing FK metadata — they don't synthesise it. Wrapper views over fact-style tables (e.g. dbt-built marts, where `relationships:` tests are SQL assertions, not DDL) typically lack FK constraints, so embeds won't work out of the box. Three workarounds, in order of decreasing effort to maintain:

- **Add `FOREIGN KEY` constraints to the underlying tables.** In dbt-postgres: `+constraints_enabled: true` (see [dbt-postgres constraints docs](https://docs.getdbt.com/reference/resource-properties/constraints)). Pure DDL, works with PostgREST's standard discovery — but flipping the flag is rarely a quick win in practice: expect non-trivial side effects on build ordering, fail-on-violation semantics, and compatibility with views that filter by `is_active` or similar soft-delete columns.
- **Define [computed relationships](https://docs.postgrest.org/en/v12/references/api/computed_relationships.html)** — SQL functions returning `SETOF <related_type>` that PostgREST recognises as relations. Significant boilerplate per relationship; useful when FK constraints are infeasible.
- **Skip embeds; consumers do two queries.** The right call when relationships are few and clients can afford the round trip. Atlas's v1 API takes this path — the `mart_*` views are designed as fat rows (joined columns inline) so external consumers don't need embeds.

If you're unsure, start without embeds and add them later if external demand surfaces.

### Column descriptions don't propagate to wrapper views

`COMMENT ON COLUMN marts.dim_kommune.name IS '…'` is **not** visible on `api_v1.kommune` defined as `CREATE VIEW api_v1.kommune AS SELECT … FROM marts.dim_kommune`. PostgREST projects empty `description` fields in the OpenAPI spec for view columns unless the consumer explicitly emits `COMMENT ON COLUMN api_v1.kommune.name IS '…'` per column. If your build pipeline already has descriptions in the underlying-table layer (e.g. dbt's `target/manifest.json`), have the migration generator re-emit them on the view.

## Example: Atlas open-data API

Atlas (`atlas.helpers.no`) publishes Norwegian public-sector and NGO supply data via PostgREST as the first consuming application of this service. Atlas is a worked-out, production-shaped example of every concept this page describes — `api_v1` schema as the public contract, role-pair anonymous access, generated views, Swagger 2.0 spec — verified end-to-end against rancher-desktop on 2026-04-30 (see [Atlas's PostgREST API contributor docs](https://github.com/terchris/atlas/blob/main/website/docs/contributors/api-v1.md)).

### The api_v1 surface

Nine wrapper views, one per `marts.mart_*` model in Atlas's curated `models/marts/api/` directory. Each is auto-generated from dbt's `target/manifest.json` rather than hand-written, so column descriptions and view definitions stay in sync with the underlying dbt model. The full list, returned by PostgREST's own `GET /` introspection:

| Endpoint | What it serves |
|---|---|
| `/indicator_summary` | One row per (source, contents_code) — coverage, latest year, min/max, upstream timestamp. The "what indicators exist and how complete are they" surface. |
| `/indicator_latest_values` | One row per (kommune, indicator, contents_code) at the latest year — the wide-table surface for kommune-level dashboards. |
| `/indicator_missing_kommuner` | Per-indicator gap report: which kommuner have null values at the latest year. |
| `/coverage_gap_barnefattigdom` | The "child poverty per kommune" cut, ordered for journalist-style "worst-N" queries. |
| `/distrikt_summary` | Kommune-level NGO presence summary (chapter counts by NGO). |
| `/ngo_index` | One row per NGO — chapter counts, geographic spread. |
| `/ngo_overview` | Per-NGO breakdown by chapter level (national/regional/local) + activity + kommune coverage. |
| `/activity_catalog` | One row per service-category-tagged activity across all NGOs. |
| `/kommune_local_chapters` | One row per (kommune, NGO chapter) for chapter-level joins. |

### Application-side: how api_v1 is built

In Atlas's data repository, the `api_v1.*` views are produced by a generator that reads dbt's `target/manifest.json` after `dbt run` finishes, then emits one `CREATE OR REPLACE VIEW api_v1.<name>` per `mart_<name>` model in the curated set, plus a `COMMENT ON COLUMN` per column (descriptions sourced from `schema.yml`, propagated by dbt-osmosis). The generator runs at PR time as part of `regenerate-api-v1.sh`; the SQL file is checked in. Apply happens after `dbt run` on a fresh database via `apply-api-v1.sh`. Five validation gates (drift, coverage, static and runtime description coverage, row-count parity vs the underlying mart) keep the wrapper layer honest.

The pattern is concrete and reproducible — see [PLAN-004](https://github.com/terchris/atlas/blob/main/website/docs/ai-developer/plans/completed/PLAN-004-postgrest-api-v1-wrapper.md) for the full design and rationale, and [api-v1.md](https://github.com/terchris/atlas/blob/main/website/docs/contributors/api-v1.md) for the contributor-facing workflow. Hand-writing wrapper views is also fine for smaller surfaces; Atlas just outgrew it once views started repeating shape.

Atlas does **not** create the `atlas_web_anon` or `atlas_authenticator` roles or grant privileges — `./uis configure postgrest` does that.

### Platform-side: configure and deploy

```bash
./uis configure postgresql --app atlas --database atlas_db --json
# (Atlas's data pipeline runs against atlas_db here — migrations, ingest, dbt, apply-api-v1.sh)

./uis configure postgrest --app atlas \
    --database atlas_db \
    --schemas api_v1,marts,raw \
    --url-prefix api-atlas
./uis deploy postgrest --app atlas
```

### Querying the API — three real access patterns

```bash
# 1. List all source/contents combinations, ordered by latest year
$ curl -sS 'http://api-atlas.localhost/indicator_summary?order=latest_year.desc&limit=2'
[{"source_id":"fhi-bor-alene","contents_code":"SMR","contents_label":"Standardisert rate (100 = nasjonalt snitt)",
  "latest_year":2025,"kommuner_with_value":357,"kommuner_with_null":0,
  "min_value":58.88,"max_value":142.27,"upstream_updated":"2026-04-30T06:22:21.532+00:00"},
 {"source_id":"fhi-bor-alene","contents_code":"RATE","contents_label":"Andel (prosent)",
  "latest_year":2025,"kommuner_with_value":357,"kommuner_with_null":0,
  "min_value":14.78,"max_value":35.71,"upstream_updated":"2026-04-30T06:22:21.532+00:00"}]

# 2. Filter by source — what does SSB 08764 (poverty rates) cover?
$ curl -sS 'http://api-atlas.localhost/indicator_summary?source_id=eq.ssb-08764&limit=2'
[{"source_id":"ssb-08764","contents_code":"EUskala50","contents_label":"EU-skala 50 prosent",
  "latest_year":2024,"kommuner_with_value":357,"kommuner_with_null":1,
  "min_value":0,"max_value":20.8,"upstream_updated":"2026-04-30T06:19:23.61+00:00"},
 {"source_id":"ssb-08764","contents_code":"EUskala60","contents_label":"EU-skala 60 prosent",
  "latest_year":2024,"kommuner_with_value":357,"kommuner_with_null":1,
  "min_value":4.6,"max_value":28.6,"upstream_updated":"2026-04-30T06:19:23.61+00:00"}]

# 3. Top-3 kommuner by child poverty rate (the "worst kommuner" journalist query)
$ curl -sS 'http://api-atlas.localhost/coverage_gap_barnefattigdom?order=value_pct.desc&limit=3'
[{"kommune_nr":"9999","kommune_name":"Uoppgitt","fylke_name":"Uoppgitt","year":2024,
  "value_pct":null,"personer":null},
 {"kommune_nr":"5630","kommune_name":"Berlevåg","fylke_name":"Finnmark","year":2024,
  "value_pct":28.6,"personer":119},
 {"kommune_nr":"3419","kommune_name":"Våler (Innlandet)","fylke_name":"Innlandet","year":2024,
  "value_pct":28.2,"personer":525}]
```

PostgREST's filter / order / limit operators handle this without any application-side code — the views are the contract, the operators are the API.

### What doesn't work in v1: FK embeds

Atlas's `api_v1.*` does **not** support PostgREST's embedded-resource pattern (`?select=*,kommune(*)`) in v1. The reason is generic and covered by the [Embedded resources require real FK constraints](#embedded-resources-require-real-fk-constraints) subsection above: Atlas's `marts.*` lacks Postgres `FOREIGN KEY` constraints because dbt's `relationships:` tests are SQL assertions rather than DDL, and PostgREST reads `pg_constraint` not dbt's manifest. Atlas's PLAN-004 [Q10] resolved this as **(c) skip embeds in v1** — `mart_*` views are designed as fat rows (joined columns inline), so external consumers don't need embeds for kommune/fylke names, NGO names, etc. Revisit later via dbt-postgres `+constraints_enabled: true` or computed relationships if external demand surfaces.

## Undeploy

```bash
# Remove K8s objects, keep Postgres roles and Secret (re-deploy works without re-configure)
./uis undeploy postgrest --app atlas

# Full teardown: drop roles, remove Secret
./uis configure postgrest --app atlas --purge
```

## Troubleshooting

### PostgREST returns 404 for a view I just added

PostgREST caches the schema at startup. After adding a view to `api_v1`, signal a reload:

```sql
NOTIFY pgrst, 'reload schema';
```

Or restart the pods: `kubectl rollout restart deployment/<app>-postgrest -n postgrest`.

### PostgREST returns 401 unauthorized for an anonymous request

The `<app>_authenticator` role lacks permission to switch to `<app>_web_anon`. `./uis configure postgrest --app <name>` grants this automatically; if you see this error after a clean configure, run `./uis configure postgrest --app <name> --rotate` to recreate the role pair, or check that the GRANT statement was not rolled back manually.

### `./uis configure postgrest` exits unexpectedly or behaves oddly

Pull the latest UIS image and try again:

```bash
./uis pull
```

`./uis pull` updates the `uis-provision-host` container to the latest published `ghcr.io/helpers-no/uis-provision-host:latest` and restarts it. Older images may carry handler bugs that have already been fixed on `main` but haven't been picked up locally yet. Re-run the failing command after the pull completes.

### `./uis configure postgrest --app <name> --purge` errors with "FATAL: database does not exist"

Pass `--database <app>_db` explicitly:

```bash
./uis configure postgrest --app atlas --database atlas_db --purge
```

Without `--database`, the purge path falls back to `<app>` as the database name (e.g. `atlas`, not `atlas_db`) and the underlying `psql -d <app>` connection fails. Tracked as a UX nit; the explicit-`--database` form is correct and matches how you'd run any other `configure` invocation.

### `./uis configure postgrest` errors with "Database '\<name\>' does not exist"

The configure precheck found no database named `<name>` in the cluster's PostgreSQL. This is the precheck working as intended — the message points at the missing prerequisite. Run step 0 first:

```bash
./uis configure postgresql --app <name> --database <name>_db --json
```

…then run your application's data pipeline against the new database so `api_v1.*` is populated, then re-run `./uis configure postgrest`.

## Out of scope

- The `api_v1` schema and view definitions — application-side work, owned by the consumer's migrations.
- pg_graphql for GraphQL endpoints — separate future investigation (`INVESTIGATE-pg-graphql.md`).
- JWT authentication and per-user RLS policies — deferred until a real authenticated-endpoint requirement appears.

## Learn More

- [Official PostgREST documentation](https://postgrest.org)

<!-- imac concurrency probe 1 -->
