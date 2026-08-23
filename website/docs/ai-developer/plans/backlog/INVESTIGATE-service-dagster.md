# Investigate: Dagster Orchestration Platform for UIS

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog — design still owns this; build plan filed 2026-08-22

⚠️ **This file is four months old (last updated 2026-04-21) and is stale in
places.** It still owns the *design*, and the design held up — OSS not Dagster+,
official Helm chart, dedicated namespace, code-locations-as-tenants, shared
Postgres with a separate metadata database, Traefik ingress, no auth day 1.

What has changed: Terje decided Dagster becomes a reusable UIS service, and Atlas
arrived as a real consumer with 41 sources (not the ~24 recorded here), 40 already
Dagster-Pipes-enabled and waiting. The build plan is
[PLAN-service-dagster-001-deploy](../completed/PLAN-service-dagster-001-deploy.md), which
reconciles this file against the consumer requirement and lists the six points
where they diverged. Read the plan first; use this for the reasoning behind the
options.

**Goal**: Deploy Dagster as the data orchestration platform in UIS, providing scheduling, observability, and lineage for data pipelines across applications — starting with Atlas, with reusability for future apps.

**Last Updated**: 2026-04-21

**Depends on:** PostgreSQL (042), Traefik ingress. Authentik (070-079) is optional — Dagster UI can run without authentication on internal networks, or behind Traefik OIDC middleware when Authentik is deployed.

**Request origin:** Atlas (`atlas-data` application) — see `~/learn/helpers/atlas/docs/stack/` for the context in which the need arose. Atlas has ~24 public data sources to ingest, with mixed cadences (annual SSB tables, daily NGO scrapes, live weather feeds for future Storm Mode extension). One operator view across all ingestion jobs is a hard requirement.

---

## Questions to Answer

1. Which Dagster distribution — **Dagster OSS** (free, self-hosted) or **Dagster+** (SaaS)?
2. Which deployment mechanism — **official Helm chart** or roll our own manifests?
3. How to deploy **user code** — the official "user-code-deployments" pattern (separate gRPC server per application) vs. co-located?
4. **Metadata storage** — reuse shared UIS PostgreSQL (new database + user), or give Dagster a dedicated instance?
5. **Auth** at day 1 — no auth (internal only), or behind Traefik + Authentik OIDC from the start?
6. **Run pod execution** — Kubernetes executor (spawns a pod per run step) or in-process?
7. **Resource footprint** — is Dagster light enough for the target UIS laptop profile, or does it require a dedicated host tier?
8. **Multi-tenant** — how do we isolate Atlas's code from a future second application's code? One deployment per app, or shared deployment with code locations?

---

## Problem Statement

UIS today has no data-pipeline orchestrator. Applications that need to ingest, transform, and catalogue data have three options — each with drawbacks:

- **Hand-rolled Kubernetes CronJobs** — works for 5 jobs. Does not scale to 20+: no single pane of view, no freshness tracking, no DAG dependencies, no UI for re-runs.
- **Application-level schedulers** — each app builds its own. Duplication across apps, no shared pattern, no shared observability.
- **Airbyte** — commercial-style ingestion tool, but only its catalogue of pre-built connectors earns its keep; for Norwegian public-sector APIs the connectors don't exist and we'd write all Custom Connectors ourselves (evaluated and rejected for Atlas; see `~/learn/helpers/atlas/docs/stack/` conversation log).

Dagster addresses this at the platform level: one orchestrator serving many applications, each shipping its own user-code image that Dagster loads as a "code location."

---

## What is Dagster?

Dagster is an open-source (Apache 2.0) data orchestrator built around the concept of **software-defined assets**. Each data product (a table, a file, a model) is an "asset" with explicit code, dependencies, schedules, freshness policies, and metadata. The Dagster UI shows every asset across every pipeline in one place.

**Distribution:** Apache 2.0, GitHub [`dagster-io/dagster`](https://github.com/dagster-io/dagster), maintained by Dagster Labs.

**Why it fits UIS:**

- **Platform-shaped, not application-shaped** — one install can host many applications as separate "code locations."
- **Language-agnostic execution** — user code can be Python (native), or via Dagster Pipes any language that writes structured stdout (TypeScript, Go, Rust, shell). Atlas's TypeScript ingestion lands cleanly here.
- **dbt integration is first-class** — every dbt model becomes a Dagster asset automatically with lineage intact.
- **Kubernetes-native** — designed to run on K8s, spawning one pod per run step.
- **Observability out of the box** — a web UI showing asset status, run history, lineage graph, schedules, freshness. Alerts via Slack / email / webhooks. Metrics as Prometheus.

### Architecture

Dagster is a multi-component system. Understanding each piece is essential for the UIS deployment.

| Component | What it does | Shape | Persistence |
|---|---|---|---|
| **Webserver (dagster-webserver)** | Serves the UI and GraphQL API. Stateless. | Long-running K8s Deployment | None |
| **Daemon (dagster-daemon)** | Runs schedules, sensors, and the run queue. Triggers runs. | Long-running K8s Deployment (singleton) | None |
| **User code deployment** | A gRPC server hosting application-specific asset/job definitions. One per code location. | Long-running K8s Deployment | None |
| **Metadata DB** | Run history, event log, schedule state, asset catalogue. The source of truth for "what happened." | PostgreSQL | Yes — must be durable |
| **Run pods** | Ephemeral K8s pods spawned by the daemon to execute a specific run step. | Short-lived K8s Pods | None (state in metadata DB) |

In practice, UIS installs the first four once. Each application (Atlas today, possibly others tomorrow) contributes a Docker image with its user code; Dagster loads it as a code location. Run pods are spawned on-demand from user code images.

### Code locations — the multi-application pattern

A **code location** is Dagster's unit of user-code deployment. Each is:

- A Docker image containing the application's asset/job definitions (Python package + any supporting tools like dbt, node runtime)
- Registered in the Dagster Helm chart's `workspace` section via a Kubernetes user-code deployment
- Loaded by the webserver and daemon on startup (or on reload)

For UIS this is the clean multi-application boundary: platform owns the Dagster install; applications ship their own user-code image.

---

## Deployment in UIS

Follow the [Adding a Service](../../../contributors/guides/adding-a-service.md) guide. This section maps Dagster to the UIS service conventions.

### Distribution: Dagster OSS (self-hosted)

Not Dagster+. Dagster+ is the SaaS offering ($800+/month team tier for its managed webserver and hosted metadata). UIS is a sovereign-infrastructure platform; self-hosted OSS is the correct match. All features relevant to Atlas (asset graph, schedules, freshness policies, dbt integration, alerts) are in OSS. Dagster+ adds branch deployments, usage analytics, and a managed UI — none of which outweigh the sovereignty requirement.

### Deployment mechanism: official Helm chart

`dagster/dagster` from `https://dagster-io.github.io/helm` — maintained by Dagster Labs, tracks the core release cadence, includes all components. This is the default for production deployments and has been battle-tested.

```bash
helm repo add dagster https://dagster-io.github.io/helm
helm install dagster dagster/dagster -n dagster -f values.yaml
```

The chart deploys webserver, daemon, and optionally user-code deployments. Rolling our own manifests would duplicate the chart's ~1,500 lines without adding value.

### Namespace

New namespace: `dagster`. Matches UIS's one-namespace-per-service-category convention (Backstage has `backstage`, Grafana is in `observability`, etc.).

### PostgreSQL: reuse shared UIS PostgreSQL

Dagster needs PostgreSQL for its metadata (run history, event log, schedule state, asset catalogue). Reuse the existing UIS shared PostgreSQL — create a new database and user:

```sql
CREATE DATABASE dagster;
CREATE USER dagster_user WITH PASSWORD '...';
GRANT ALL PRIVILEGES ON DATABASE dagster TO dagster_user;
```

Dagster's metadata is modest (tens of MB for a typical install; low hundreds of MB for a year of run history at high volume). No reason to provision a dedicated instance.

### Ingress: Traefik

Same pattern as Backstage, Grafana, etc. The Dagster webserver exposes HTTP on port 80 inside the cluster; Traefik routes `dagster.sovereignsky.no` (or similar) to it.

### Auth strategy

Two options, both viable:

- **Day 1 — no auth.** Acceptable if the Dagster UI is reachable only from the UIS internal network or via Tailscale. Lowest complexity.
- **Day 2 — Authentik OIDC via Traefik middleware.** Adds a Traefik `forwardAuth` middleware that redirects unauthenticated requests to Authentik. Dagster OSS has no built-in auth, so this is the standard pattern.

Recommended: start with no auth (Dagster is an operator tool, not public), move to OIDC when Authentik deployment is stable.

### Metrics and logging

- **Metrics**: Dagster exposes Prometheus metrics on the daemon and webserver. Add a `ServiceMonitor` for Prometheus to scrape. Metrics include run counts, scheduler lag, asset freshness violations.
- **Logs**: Structured JSON to stdout, scraped by Loki via the existing UIS log pipeline. No special config needed.

### Resource footprint (estimated)

Based on Dagster's published sizing guide and typical OSS deployments:

| Component | CPU Request | CPU Limit | Memory Request | Memory Limit | Replicas |
|---|---|---|---|---|---|
| Webserver | 100m | 500m | 256 Mi | 512 Mi | 1–2 |
| Daemon | 100m | 500m | 512 Mi | 1 Gi | 1 (singleton) |
| User-code (per code location, e.g. `atlas-data`) | 100m | 500m | 256 Mi | 512 Mi | 1 |
| Run pods | 100m | 1000m | 256 Mi | 1 Gi | ephemeral |

Baseline (webserver + daemon + one user-code + metadata in shared PG): **~1 Gi memory, 300m CPU**. Within the UIS laptop profile.

Run pods add bursty load during pipeline execution; for Atlas's expected load (ingestion runs typically finish in seconds–minutes) this is modest.

---

## How Atlas will use it

Atlas (the first consumer) has its own repo `atlas-data` containing:

- TypeScript ingestion code (`ingest/src/sources/*.ts`) — one file per data source
- dbt project (`dbt/`) — transformations from raw landing to serving tables
- Dagster user code (`dagster/atlas_data/`) — `@asset` definitions that invoke the ingestion via Dagster Pipes and auto-load the dbt models as downstream assets

CI builds one Docker image with all three. UIS ArgoCD picks up the image tag and reconfigures Dagster's user-code deployment to load it.

Once deployed, the Dagster UI at `dagster.sovereignsky.no` (or equivalent) shows:

- ~24 Atlas assets (one per data source) with status, last run, freshness
- ~10–20 dbt models as downstream assets with lineage back to the sources
- Schedules for each source (annual, monthly, daily depending on the upstream)
- Sensors for SSB release-calendar polling

This is "Atlas's data platform" as seen from inside Dagster. A future second application on UIS contributes its own user-code image and adds its own asset group without touching Atlas's.

Reference: the full data journey for one Atlas source is documented in ``~/learn/helpers/atlas/docs/stack/data-journey-ssb-08764.md``.

---

## Options

### Option A: Dagster OSS + official Helm chart + shared Postgres + no auth (day 1)

**Pros:**
- Matches the Backstage pattern already used in UIS
- Low operational overhead; fewest moving parts
- Reuses UIS PostgreSQL and observability
- Rolls forward cleanly to Authentik OIDC later

**Cons:**
- No auth on day 1 — must rely on network-level access control
- One singleton daemon is a single point of failure (manageable; restarts are seconds)

### Option B: Dagster OSS + official Helm chart + dedicated Postgres

**Pros:**
- Metadata isolation from other UIS workloads
- Can tune Postgres for Dagster-specific workload (high write rate during heavy runs)

**Cons:**
- Extra service to operate for marginal benefit
- Shared PG is already production-scale; Dagster metadata is modest

### Option C: Dagster+ (SaaS)

**Pros:**
- Zero install
- Managed UI, hosted metadata
- Branch deployments for testing

**Cons:**
- Per-user pricing (~$800+/month for team tier)
- **Violates UIS's sovereignty principle** — metadata and orchestration state leave the sovereign environment
- Unavailable if Dagster Labs has an outage

### Option D: Roll our own manifests (no Helm chart)

**Pros:**
- No dependency on chart maintainer

**Cons:**
- Reimplements ~1,500 lines of Helm chart
- Higher maintenance burden on every Dagster version bump
- No material benefit

---

## Recommendation

**Option A** — Dagster OSS + official Helm chart + shared Postgres + no auth day 1, with Traefik + Authentik OIDC middleware added as a follow-up.

This mirrors the proven Backstage pattern, reuses every existing UIS component, and stays entirely within the sovereign infrastructure.

---

## Next Steps

Following the [PLANS.md](../../PLANS.md) guidance on splitting investigations into ordered plans:

- [ ] **PLAN-001-dagster-deployment.md** — Deploy Dagster OSS via the official Helm chart into the `dagster` namespace, using shared UIS PostgreSQL, with Traefik ingress and no auth. Verify webserver reachable and daemon healthy.
- [ ] **PLAN-002-dagster-code-location-atlas.md** — Register the `atlas-data` application as the first Dagster code location. Reload from webserver UI; verify assets visible.
- [ ] **PLAN-003-dagster-auth-authentik.md** *(optional, after Authentik is stable)* — Put Dagster UI behind Traefik OIDC middleware.
- [ ] **PLAN-004-dagster-alerts.md** *(optional)* — Wire Dagster alerts to Slack / email via webhooks.

Before writing the PLAN files, answer Questions 1–8 above (recommendations noted inline).

---

## Files to Modify

Scoped to UIS repo:

- `manifests/###-dagster.yaml` *(TBD numbering per UIS conventions; likely ###–### range for orchestration category)*
- `provision-host/uis/services/<dagster>/` — Ansible playbook, defaults, verification
- `website/docs/services/<appropriate-category>/dagster.md` — service documentation page
- `templates/uis.secrets/dagster-secrets.yml` — PG credentials, webhook secrets
- Cross-link from the Atlas project's `atlas-data/deploy/` (future — a separate PLAN will cover code-location registration)
