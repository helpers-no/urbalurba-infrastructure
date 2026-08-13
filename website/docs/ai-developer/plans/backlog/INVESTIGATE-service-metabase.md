# Investigate: Metabase Internal BI / Data Exploration for UIS

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: Deploy Metabase as the internal data-exploration and validation tool for UIS-hosted applications, providing visual SQL exploration, ad-hoc questions, and dashboards for development teams — starting with Atlas, with reusability for future apps.

**Last Updated**: 2026-04-22

**Depends on:** PostgreSQL (042), Traefik ingress. Authentik (070-079) is optional — Metabase OSS has built-in user management; Authentik OIDC integration via Traefik `forwardAuth` middleware is a follow-up. Tailscale tunnel (or equivalent network-level gating) is recommended day 1 since Metabase is an internal-team tool, not a public BI product.

**Request origin:** Atlas (`atlas-data` application) — see `~/learn/helpers/atlas/docs/stack/suggested-stack.md` for the context. Atlas now has 19 ingested sources in `raw.*`, with `marts.*` (dim spine + fact tables) under construction. Visual exploration across sources is needed for: (1) data-quality validation, (2) discovery of cross-source relations during dim-spine modelling, and (3) ad-hoc questions from the development team. Originally deferred to v1.5; pulled forward now that source count crossed the threshold where psql/pgAdmin alone is no longer sufficient.

---

## Questions to Answer

1. Which Metabase distribution — **Metabase OSS** (free, AGPL, self-hosted) or **Metabase Pro/Cloud** (commercial)?
2. Which deployment mechanism — community Helm chart (e.g. `pmint93/metabase`) or roll our own manifests from the official Docker image?
3. **Metadata storage** — reuse shared UIS PostgreSQL (new `metabase` database + user), or use Metabase's default H2 (file-based, not production-safe), or a dedicated instance?
4. **Auth at day 1** — built-in Metabase user management with admin-created accounts, or Traefik + Authentik OIDC `forwardAuth` middleware from the start?
5. **Network exposure** — Tailscale-gated only (recommended) or public ingress via Cloudflare?
6. **Resource footprint** — Metabase is JVM-based and noticeably heavier than most UIS services; is it within the laptop profile?
7. **Multi-tenant** — single shared Metabase instance with per-application database connections (recommended), or one Metabase per application?
8. **Data-source connection pattern** — direct read-only role on each application's serving schema (e.g. `atlas_marts_reader` on `atlas` DB), or a separate connection per environment?

---

## Problem Statement

UIS today has no general-purpose data-exploration UI. Applications that produce data into Postgres have three options for inspecting and validating it — each with drawbacks:

- **psql / pgAdmin** — works for ad-hoc one-off queries. Does not scale: no saved questions, no visualisations, no shareable dashboards, no cross-team discovery.
- **JupyterHub** — already in UIS but is a notebook tool for analysts comfortable with Python/SQL code. Wrong audience and workflow for "I just want to see this trend as a chart."
- **Hand-built Next.js admin pages** — every application reimplements browse/filter/chart UI. Duplication across apps, no shared pattern.

For Atlas specifically, with 19 ingested sources and `marts.*` under construction, the team needs to visually compare sources (e.g. is `ssb-06947` whole-population low-income consistent with `ssb-08764` children low-income?), spot data-quality issues (orphan kommune codes, residual `"99 Uoppgitt"`), and validate dim-spine joins as they are built. SQL alone is too slow a feedback loop at this scale.

Metabase addresses this at the platform level: one install can host many applications as separate database connections, with collections per application for organising questions and dashboards.

---

## What is Metabase?

Metabase is an open-source (AGPLv3) business-intelligence and data-exploration tool built around the concept of **questions** (saved queries with visualisations) and **dashboards** (collections of questions). The Metabase UI provides a visual query builder for non-SQL users, a SQL editor for analysts, and an admin interface for managing data sources and permissions.

**Distribution:** AGPL v3 OSS, GitHub [`metabase/metabase`](https://github.com/metabase/metabase), maintained by Metabase, Inc. Commercial Pro and Cloud tiers add SSO (SAML/JWT), advanced permissions, white-labelling, and embedded analytics.

**Why it fits UIS:**

- **Platform-shaped, not application-shaped** — one install can serve many applications via separate database connections and collection isolation.
- **Connects to anything in UIS** — PostgreSQL (primary), MySQL, MongoDB, Elasticsearch are all in UIS and all are first-class Metabase data sources.
- **Visual query builder + SQL editor** — covers both non-technical exploration and analyst SQL workflows in one tool.
- **Dashboards and collections** — saved questions can be grouped into dashboards; collections provide per-application organisation and (in OSS) basic permissions.
- **Lightweight to operate** — single JVM process, optional Postgres metadata DB, Helm-deployable.

### Architecture

Metabase is a single-process system with an external metadata DB. Simpler than Dagster but with a heavier per-process footprint due to JVM.

| Component | What it does | Shape | Persistence |
|---|---|---|---|
| **Metabase server (JVM)** | Serves the UI, query API, and runs scheduled question refreshes. Stateful in memory but state is reconstructible from the metadata DB. | Long-running K8s Deployment | Caches in memory; durable state in metadata DB |
| **Metadata DB** | Users, permissions, saved questions, dashboards, collections, query cache, schedule state. The source of truth for "everything Metabase knows." | PostgreSQL (production) or H2 (default, file-based — **do not use in production**) | Yes — must be durable |
| **Connected data sources** | Read-only Postgres connections to application serving schemas (e.g. `atlas.marts.*`). Configured in the admin UI. | External services | N/A |

In practice, UIS installs one Metabase server, with metadata in shared UIS PostgreSQL. Each application registers its serving schema as a data source with a dedicated read-only role.

### Data-source connection pattern — the multi-application boundary

Each application (Atlas today, others tomorrow) provisions a Metabase-only read-only role in its database:

```sql
-- in the `atlas` database
CREATE ROLE metabase_atlas_reader WITH LOGIN PASSWORD '...';
GRANT USAGE ON SCHEMA marts TO metabase_atlas_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA marts TO metabase_atlas_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA marts GRANT SELECT ON TABLES TO metabase_atlas_reader;
```

The Metabase admin then registers `atlas` as a database with this role. Collections in Metabase are organised per-application; permissions ensure team A doesn't see team B's questions.

For UIS this is the clean multi-application boundary: platform owns the Metabase install; applications provide a read-only role and own their collection.

---

## Deployment in UIS

Follow the [Adding a Service](../../../contributors/guides/adding-a-service.md) guide. This section maps Metabase to the UIS service conventions.

### Distribution: Metabase OSS (self-hosted)

Not Metabase Pro or Cloud. Pro adds SSO (SAML/JWT), advanced permissions, white-labelling, and starts at ~$85/user/month. Cloud is hosted by Metabase, Inc. UIS is a sovereign-infrastructure platform; self-hosted OSS is the correct match.

The major OSS limitation is **no built-in SSO** — Metabase OSS supports email/password and Google OAuth only. SSO with Authentik must be done via Traefik `forwardAuth` middleware (Metabase still maintains its own user records, but auth is gated by Authentik). This is the same pattern UIS uses for Dagster and Backstage.

### Deployment mechanism: community Helm chart

Metabase does not publish an official Helm chart. The most-maintained community chart is `pmint93/metabase` ([github.com/pmint93/helm-charts](https://github.com/pmint93/helm-charts)), which is widely used and tracks Metabase's release cadence reasonably well.

```bash
helm repo add pmint93 https://pmint93.github.io/helm-charts
helm install metabase pmint93/metabase -n metabase -f values.yaml
```

Alternative: roll our own minimal manifests from the official Docker image (`metabase/metabase`). This is viable because Metabase is a single Deployment + Service + ConfigMap; the chart is not load-bearing. Recommend the chart for default and revisit if maintenance lags.

### Namespace

New namespace: `metabase`. Matches UIS's one-namespace-per-service convention.

### PostgreSQL: reuse shared UIS PostgreSQL — and do not use H2

Metabase needs a metadata DB for users, questions, dashboards, etc. The default H2 (file-based, embedded) is **explicitly unsupported for production** by Metabase upstream — it cannot be backed up safely, does not survive pod restarts cleanly, and corrupts on hard kills.

Reuse the existing UIS shared PostgreSQL — create a new database and user:

```sql
CREATE DATABASE metabase;
CREATE USER metabase_user WITH PASSWORD '...';
GRANT ALL PRIVILEGES ON DATABASE metabase TO metabase_user;
```

Configure via env vars on the Metabase pod:

```yaml
MB_DB_TYPE: postgres
MB_DB_HOST: postgresql.databases.svc.cluster.local
MB_DB_PORT: 5432
MB_DB_DBNAME: metabase
MB_DB_USER: metabase_user
MB_DB_PASS: <from secret>
```

Metadata is modest — typically 50–500 MB depending on saved-question volume.

### Ingress: Traefik

Same pattern as Backstage and (planned) Dagster. Metabase exposes HTTP on port 3000 inside the cluster; Traefik routes `metabase.sovereignsky.no` (or similar) to it.

### Network exposure: Tailscale-only day 1

Metabase is an internal team tool, not a public BI product for end users (that role belongs to the application's own frontend — for Atlas, Next.js). Recommend gating Metabase access behind Tailscale at day 1, the same as Dagster UI. Public Cloudflare ingress is not needed and adds attack surface for no benefit.

### Auth strategy

Two options, both viable:

- **Day 1 — built-in Metabase user management.** Admin manually invites the development team. Acceptable while Metabase is Tailscale-gated and the user set is small (the Atlas team). Lowest complexity.
- **Day 2 — Authentik OIDC via Traefik `forwardAuth` middleware.** Adds a Traefik middleware that redirects unauthenticated requests to Authentik. Metabase still maintains its own user records (the OSS limitation), but those records can be auto-created on first login if Metabase's "Login attribute" is mapped to the Authentik claim. Same pattern as Dagster.

Recommended: start with built-in auth (the team is small, network is gated), move to OIDC when Authentik deployment is stable and a non-trivial user base appears.

### Metrics and logging

- **Metrics**: Metabase exposes basic JVM and HTTP metrics on `/api/health` and (with the `MB_JETTY_STATS_ENABLED=true` flag) Jetty stats. There is no native Prometheus exporter; for richer metrics, run a JMX exporter sidecar. Acceptable to start without metrics — the metadata DB itself records query volume.
- **Logs**: Structured JSON to stdout when `MB_LOG_FORMAT=json` is set, scraped by Loki via the existing UIS log pipeline.

### Resource footprint (estimated)

Based on Metabase's published sizing guide and typical OSS deployments. Metabase is JVM-based — noticeably heavier than most UIS services.

| Component | CPU Request | CPU Limit | Memory Request | Memory Limit | Replicas |
|---|---|---|---|---|---|
| Metabase server | 200m | 1000m | 1 Gi | 2 Gi | 1 (singleton OK in OSS) |

Baseline (Metabase server + metadata in shared PG): **~1 Gi memory, 200m CPU steady-state, bursts to 2 Gi during heavy queries**. Within the UIS laptop profile but not negligible — comparable to a single Backstage or Dagster webserver pod.

JVM tuning: set `JAVA_OPTS=-Xmx1500m` to keep heap predictable.

---

## How Atlas will use it

Atlas (the first consumer) will use Metabase for three workflows:

1. **Data-quality validation across 19+ sources.**
   - Question: "show me yearly counts for `raw.ssb_06947` vs `raw.ssb_08764` for kommune 0301 (Oslo) — do trends agree?"
   - Question: "list all kommune codes appearing in `raw.*` tables that are NOT in `marts.dim_kommune`" — surfaces orphan codes for the dim spine.
   - Saved as a "Data Quality" collection.

2. **Dim-spine modelling support.**
   - Visual join builder: pick `raw.fhi_bor_alene` and `marts.dim_kommune`, drag join on `kommune_nr`, see overlap. Faster than writing test SQL by hand.
   - Saved as a "Dim Spine Validation" collection.

3. **Ad-hoc team questions.**
   - "What's the trend of single-parent share by fylke since 2010?" "Which kommuner have the largest 5-year change in low-income share?"
   - These often become the seed for a future Next.js dashboard page or a worked example in the public API docs.
   - Saved as a "Atlas Exploration" collection.

A single Metabase database connection (`atlas`, using `metabase_atlas_reader` role) gives access to both `raw.*` and `marts.*` schemas. Collection-level organisation keeps the workflows separate.

Reference: the full data journey for one Atlas source is documented in ``~/learn/helpers/atlas/docs/stack/data-journey-ssb-08764.md``. The corresponding source READMEs live in `~/learn/helpers/atlas/atlas-data-repo/ingest/src/sources/`.

**What Metabase is *not* used for in Atlas:**
- The public-facing Atlas portal (that is Next.js → Postgres direct).
- Public open-data APIs (that role belongs to PostgREST — see [`INVESTIGATE-postgrest.md`](../completed/INVESTIGATE-postgrest.md)).
- Multi-tenant end-user dashboards (Cube was evaluated for this and rejected; see Atlas stack doc).

---

## Options

### Option A: Metabase OSS + community Helm chart + shared Postgres + built-in auth + Tailscale gating (day 1)

**Pros:**
- Matches the Backstage / planned-Dagster pattern in UIS
- Lowest operational overhead; fewest moving parts
- Reuses UIS PostgreSQL and Tailscale
- Rolls forward cleanly to Authentik OIDC later

**Cons:**
- Built-in user management requires manual admin invites — acceptable for a small team
- Community Helm chart is not maintained by Metabase upstream; lag risk on major versions

### Option B: Metabase OSS + community Helm chart + shared Postgres + Authentik OIDC from day 1

**Pros:**
- Single sign-on from day 1; no separate Metabase password to manage
- Aligns with the long-term UIS auth direction

**Cons:**
- Couples Metabase install to Authentik stability
- Metabase OSS has no native OIDC — relies on Traefik `forwardAuth` plus Metabase's `MB_JWT_SHARED_SECRET` for JWT-based provisioning, which is fiddly to set up
- More to debug if first-time login fails

### Option C: Roll our own manifests (no Helm chart)

**Pros:**
- No dependency on community chart maintainer
- Metabase is simple enough (Deployment + Service + ConfigMap + Secret) that hand-rolled manifests are ~100 lines

**Cons:**
- Reimplements the chart's templating
- Slightly higher maintenance burden on every Metabase version bump
- Still viable as a fallback if the community chart goes unmaintained

### Option D: Metabase Cloud or Pro

**Pros:**
- Zero install; managed updates
- Native SSO (SAML/JWT)
- White-labelling and embedded analytics if Atlas eventually wants public dashboards

**Cons:**
- Per-user pricing (~$85/user/month for Pro)
- **Violates UIS's sovereignty principle** — application data leaves the sovereign environment when queried
- Unavailable if Metabase, Inc. has an outage
- Cost grows with team size

### Option E: Don't deploy Metabase; rely on JupyterHub + pgAdmin

**Pros:**
- Zero new services
- JupyterHub and pgAdmin are already in UIS

**Cons:**
- Neither provides shareable dashboards or saved-question collections
- Wrong audience for "I want to see a chart, not write Python or raw SQL"
- The Atlas team has hit the threshold (19 sources) where this is already painful

---

## Recommendation

**Option A** — Metabase OSS + community Helm chart (`pmint93/metabase`) + shared Postgres + built-in auth + Tailscale gating, with Traefik + Authentik OIDC middleware added as a follow-up.

This mirrors the Backstage and planned-Dagster patterns, reuses every existing UIS component, and stays entirely within the sovereign infrastructure. Roll our own manifests (Option C) as fallback if the community chart goes unmaintained.

---

## Next Steps

Following the [PLANS.md](../../PLANS.md) guidance on splitting investigations into ordered plans:

- [ ] **PLAN-001-metabase-deployment.md** — Deploy Metabase OSS via the `pmint93/metabase` Helm chart into the `metabase` namespace, using shared UIS PostgreSQL for metadata, with Traefik ingress and Tailscale gating. Verify UI reachable, first admin user created, metadata persisted across pod restart.
- [ ] **PLAN-002-metabase-data-source-atlas.md** — Provision the `metabase_atlas_reader` role in the `atlas` database, register Atlas as a data source in Metabase, create the initial three collections (Data Quality, Dim Spine Validation, Atlas Exploration). Verify queries against `raw.*` and `marts.*` succeed.
- [ ] **PLAN-003-metabase-auth-authentik.md** *(optional, after Authentik is stable)* — Put Metabase UI behind Traefik OIDC middleware; configure JWT-based user auto-provisioning.
- [ ] **PLAN-004-metabase-backups.md** *(optional)* — Add Metabase metadata DB to the UIS Postgres backup rotation; document restore procedure.

Before writing the PLAN files, answer Questions 1–8 above (recommendations noted inline).

---

## Files to Modify

Scoped to UIS repo:

- `manifests/###-metabase.yaml` *(TBD numbering per UIS conventions; likely in the analytics or applications category)*
- `provision-host/uis/services/<metabase>/` — Ansible playbook, defaults, verification
- `website/docs/services/<appropriate-category>/metabase.md` — service documentation page
- `templates/uis.secrets/metabase-secrets.yml` — PG credentials, JWT shared secret (for future OIDC)
- Cross-link from the Atlas project's data-source provisioning notes (separate PLAN will cover the `metabase_atlas_reader` role and connection registration)
