# Investigate: PostgREST as a UIS service

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: Decide whether and how to package PostgREST as a UIS service that turns a curated PostgreSQL schema into a public REST API, fitting the existing `./uis deploy` flow and the contributor conventions in [`website/docs/contributors/`](../../../contributors/index.md).

**Last Updated**: 2026-04-29 (Atlas-feedback addendum added)

**Request origin**: A prior research note (`INVESTIGATE-postgrest.md` in this directory, written before this revision) proposed PostgREST for the Atlas open-data application. That note was treated as a request — this file re-scopes the work as a *platform* service question following UIS conventions, rather than an application-specific design.

**Depends on**: PostgreSQL service (`042-postgresql-config.yaml`), Traefik ingress, optional Cloudflare Tunnel for public exposure.

---

## Addendum: 2026-04-29 — Atlas verification feedback (case (c) design gap)

Source: Atlas verification feedback (2026-04-29). Atlas ran four pre-flight experiments against the design proposed below and surfaced one design gap that affects the role-creation SQL recorded in §"How configure works (per-instance)" → "What configure generates" (lines 219–225 of the original draft). Recorded as an addendum per [PLAN-001-postgrest-documentation.md](./PLAN-001-postgrest-documentation.md) Phase 4.3 case (c) — the existing decisions are *not* modified; the new constraint and its implementation impact are documented here so PLAN-002 picks it up.

**The gap.** The role-creation SQL grants `SELECT` on **existing** tables/views in `api_v1` at the moment configure runs:

```sql
GRANT SELECT ON ALL TABLES IN SCHEMA api_v1 TO <app>_web_anon;
```

Postgres does not auto-grant on objects created later. The failure mode: a consumer adds a new view to `api_v1` after configure has run, PostgREST's schema cache reloads via `NOTIFY pgrst, 'reload schema'`, the OpenAPI spec lists the new view — but anonymous requests get `401 Unauthorized` or empty results because `<app>_web_anon` has no `SELECT` privilege on the new object. Silent until someone re-runs configure. Atlas's experiment 3 reproduced this against a synthetic `pgrst_q*_marts` / `pgrst_q*_api` pair on the platform's PostgreSQL.

**The fix — one extra line in the configure handler's SQL block.** After the existing `GRANT SELECT ON ALL TABLES…` line:

```sql
ALTER DEFAULT PRIVILEGES IN SCHEMA api_v1 GRANT SELECT ON TABLES TO <app>_web_anon;
```

This grants `SELECT` on **future** tables/views in `api_v1` automatically. Belt-and-suspenders alongside the existing GRANT-on-existing line. Idempotent; safe to re-run.

**Implementation impact.** [PLAN-002-postgrest-deployment.md](./PLAN-002-postgrest-deployment.md) Phase 2.4 (the `configure-postgrest.sh` create-path SQL block) must include this `ALTER DEFAULT PRIVILEGES` statement. The line is small but load-bearing — without it, every consumer of UIS PostgREST has to either re-run configure on every schema change, or distribute the fix to their own migrations (Atlas's PLAN-004 emits guarded grants as a workaround if UIS doesn't ship this). The "fix once in UIS" path is cleaner and matches the "schema and roles are application-side / platform deploys PostgREST and documents the contract" boundary stated below.

**Two related Atlas findings, captured for completeness:**

- **FK embeds require actual Postgres `FOREIGN KEY` constraints** — PostgREST's `?select=*,kommune(*)` embedding pattern reads `pg_constraint`. `@source` / `@references` comment hints don't synthesise FK metadata. Wrapper views over fact-style tables (e.g. dbt-built marts) typically lack FK constraints, so embeds won't work out of the box. **Documentation impact only** — this is a consumer-side reality, not a platform decision; addressed by a new subsection in [`website/docs/services/integration/postgrest.md`](../../../services/integration/postgrest.md), not a new decision here.
- **Column descriptions don't propagate to wrapper views** — `COMMENT ON COLUMN marts.*.col` is not visible on `api_v1.* AS SELECT * FROM marts.*` views; consumers must re-emit `COMMENT ON COLUMN api_v1.*.col` explicitly if they want descriptions in PostgREST's OpenAPI output. Atlas-side concern; small note added to `postgrest.md`.

**No changes to existing decisions.** Decisions #4 (`api_v1` schema of views), #6 (per-app secret), #7 (per-app prefix on roles), #18 (lifecycle), and §"What configure generates" all remain as written. The addendum is purely additive: PLAN-002's SQL block is one line longer, and the docs page gets two new short subsections.

— end of addendum —

---

## Decisions

Resolved during the 2026-04-27 review (kept here as decisions, not open questions). All design questions are now answered; the next step is for someone to write PLAN-001 with concrete implementation tasks.

| # | Topic | Decision |
|---|---|---|
| 1 | Category & number | `SCRIPT_CATEGORY="INTEGRATION"`, service number `088` (next to Gravitee at 090). Number applies to playbook filenames and Jinja templates; no static `manifests/088-*` files (see Decision #21) |
| 2 | Deployment mechanism | Hand-rolled manifests; no Helm chart |
| 3 | Multi-database model | **One PostgREST Deployment per project**, all sharing the `postgrest` namespace and the platform's `default/postgresql` instance. Each instance configured independently via `./uis configure postgrest --app <name>` |
| 4 | Schema contract | `api_v1` schema of views only — required convention, documented in the service page |
| 5 | Auth day 1 | Anonymous read-only (`<app>_web_anon`); JWT/Authentik in PLAN-003 |
| 6 | Secrets | One secret per app in the shared `postgrest` namespace, named `<app>-postgrest` with keys `PGRST_DB_URI` and (later) `PGRST_JWT_SECRET`. **Parallel shape, not reuse:** the existing `configure-postgresql.sh` pattern produces `<prefix>-db` (key `DATABASE_URL`) where the *caller's application* mounts the secret — caller picks namespace and prefix via `--namespace` / `--secret-name-prefix`. PostgREST inverts the consumer: the PostgREST Deployment itself mounts the secret, and lives in the platform-decided `postgrest` namespace. There is no caller-meaningful override. **`configure-postgrest.sh` therefore rejects `--namespace` and `--secret-name-prefix` with an instructive error** rather than accepting them with a redundant default — an override would land the secret in a namespace the PostgREST Deployment can't read from. The accepted flag set is `--app`, `--database`, `--schema`, `--url-prefix`, plus the future `--rotate` / `--purge` (Decisions #17, #18) |
| 7 | Postgres role naming | **Per-app prefix** — `<app>_web_anon`, `<app>_authenticator`. Roles are cluster-wide in Postgres, so unprefixed names would collide between projects on the shared instance |
| 8 | Stack membership | **None — standalone service.** PostgREST is not in any stack. Deploy is always explicit per-app (`./uis deploy postgrest --app <name>`); no `./uis deploy <stack>` path activates it |
| 9 | Backstage API metadata | `SCRIPT_CONSUMES_APIS="postgresql"`. `SCRIPT_PROVIDES_APIS=""` with a TODO comment — multi-instance Backstage shape deferred until Backstage is actually deployed (see [`INVESTIGATE-backstage.md`](INVESTIGATE-backstage.md)). When that happens, the docs generator should emit one `kind: API` entry per configured instance |
| 10 | Probes | Use PostgREST's admin server (`PGRST_ADMIN_SERVER_PORT=3001`) — `/live` for liveness, `/ready` for readiness. Best-practice as of PostgREST 11+ |
| 11 | CORS | `PGRST_SERVER_CORS_ALLOWED_ORIGINS` configured per instance (default `*` for the public Atlas case; per-origin for authenticated installs) |
| 12 | Schema reload | Document both options: `NOTIFY pgrst, 'reload schema'` from Postgres for hot reload, or `kubectl rollout restart deployment` for a clean cycle |
| 13 | pg_graphql | Split into `INVESTIGATE-pg-graphql.md` (Postgres-extension policy question, not a PostgREST one) |
| 14 | JWT signing-key rotation | Deferred to PLAN-003 |
| 15 | Connection pool sizing | Default `PGRST_DB_POOL=10` per pod; revisit when load is observed |
| 16 | CLI shape for multi-instance | Use the existing `--app <name>` pattern (same as `./uis configure postgresql --app <name>`). Applies to `configure`, `deploy`, `undeploy`, `verify`, `status`. `--url-prefix` defaults to `api-${app}` when omitted; explicit override is allowed for cases where the URL host label should differ from the internal app name (e.g. `--app atlas-prod --url-prefix api-atlas`). `--database` defaults to `${app}` when omitted, matching the postgresql configure default. `--schema` defaults to `api_v1` (Decision #4) |
| 17 | Idempotent configure | Re-running `./uis configure postgrest --app <name>` is a no-op when role and secret exist. A `--rotate` flag generates a new password for the existing `<app>_authenticator` and updates the Secret. **Deliberate divergence from `configure-postgresql.sh`:** the postgresql handler currently resets the password on every re-configure (`configure-postgresql.sh:184-198`) — destructive by default, no opt-in. PostgREST inverts this: safe-by-default no-op, destructive only with `--rotate`. Reason: postgresql configure is typically called by application bootstrap flows where re-running means "give me my credential back" and a reset is acceptable (the caller is the secret consumer and updates immediately). PostgREST configure is invoked by an operator and a rotation invalidates a running PostgREST Deployment's connection pool until the pod is restarted — silent destructive behavior would be a foot-gun. The two handlers can stay divergent; document the difference in the user-facing docs |
| 18 | Lifecycle (configure / deploy / undeploy) | Configure and deploy are explicit two steps; deploy errors if not configured. Undeploy removes only K8s objects, leaving Postgres roles intact for clean re-deploy. `./uis configure postgrest --app <name> --purge` drops the Postgres roles |
| 19 | `./uis list` and `status` shape | **Day-1 (PLAN-001):** `./uis list` shows the service once with an `instances: N configured` annotation. `./uis status` reports a single line `N instances configured` for postgrest (no per-row detail yet). Convention-based: formatters query `kubectl get deploy -n <SCRIPT_NAMESPACE> -l app.kubernetes.io/name=<SCRIPT_ID>` and parse instance names from deployment names — no new metadata field. **Deferred:** full per-instance row reporting (one row per `<app>-postgrest` deployment with ready/desired counts) is its own plan. That work is user-facing formatter polish across every service display path and is best scoped separately so PLAN-001 stays narrow. Once delivered, it also closes the UX wart from Decision #22 (zero-instance postgrest showing as "not running") |
| 20 | Configure output contract | Plain output: "next step" hint pointing at `./uis deploy postgrest --app <name>`. `--json` mode: `{app, namespace, secret, in_cluster_url, public_url_prefix}` — no credentials (they stay in-cluster) |
| 21 | Manifest rendering location | **Establishes a new convention.** No `.j2` files or `templates/` directory exist anywhere in `ansible/` today — every existing service uses static `manifests/*.yaml` applied via `kubernetes.core.k8s: src: ...`. PostgREST is the first multi-instance service and cannot use that pattern, since each instance needs `_app_name` / `_url_prefix` substituted in. PLAN-001 introduces `ansible/playbooks/templates/088-postgrest-*.yml.j2`, rendered by the setup playbook via `kubernetes.core.k8s` with `definition: "{{ lookup('template', '...') }}"`. The pattern: `manifests/` stays the home for static, single-instance YAML; `ansible/playbooks/templates/` is the home for rendered, per-instance YAML. Future multi-instance services follow the same path. Contributor docs must be updated to teach this distinction (see Files to Modify) |
| 22 | `SCRIPT_CHECK_COMMAND` shape | `kubectl get deploy -n postgrest -l app.kubernetes.io/name=postgrest --no-headers 2>/dev/null \| grep -qE '\s([1-9][0-9]*)/\1\s'` — passes if at least one Deployment has ready replicas == desired (and desired > 0). Zero configured instances → check fails → status shows "not running," which is correct |
| 23 | Multi-instance lifecycle flag | **New `multiInstance: true` field in `services.json`** (and corresponding `SCRIPT_MULTI_INSTANCE="true"` in `service-postgrest.sh`). Resolves the precheck conflict in `configure.sh:165`: the current `_is_service_deployed(service_id)` check fails for PostgREST on a fresh cluster (zero instances → SCRIPT_CHECK_COMMAND fails → configure errors before the handler runs). With this flag, configure's precheck shifts semantics from "is the service itself deployed" to "is the data plane this configure operation will talk to deployed." For single-instance services the two are equivalent (no behavior change). For PostgREST (multiInstance=true), the precheck reads `SCRIPT_REQUIRES` (already `"postgresql"`) and checks *those* services instead. **Implementation in `configure.sh`:** when `multiInstance=true`, iterate dependencies from `requires` field and run each dep's `checkCommand`; error with "Cannot configure postgrest: dependency 'postgresql' is not deployed. Deploy it first: ./uis deploy postgresql" if any fails. **The same flag also drives:** (a) `./uis status` / `./uis list` per-instance reporting (Decision #19) — formatters branch on `multiInstance`; (b) `./uis deploy` / `undeploy` / `verify` / `status` requiring `--app <name>` for multi-instance services (resolves the CLI plumbing question — `uis-cli.sh` reads the flag to decide whether `--app` is required and whether to translate it into `--extra-vars "_app_name=<name>"`). One metadata field, three behaviors — captures the underlying architectural distinction rather than special-casing service IDs |

---

## Current State

UIS has no service that turns a Postgres schema into a generated REST API. Applications that want to publish data have three workarounds today, all unsatisfying:

- Hand-build a NestJS / Express API per app (one custom endpoint per resource, every relation re-implemented in TypeScript).
- Expose Postgres directly through a port-forward — never acceptable for public traffic.
- Skip the API and serve only through the application's own frontend.

Adjacent services already in UIS:

| Manifest | Service | Role | Relation to PostgREST |
|---|---|---|---|
| `042-postgresql-config.yaml` | PostgreSQL | Data store | The database PostgREST connects to |
| `090-gravitee-config.yaml` | Gravitee | API gateway | Different layer — gateways/proxies APIs, doesn't generate them |
| `091-gravitee-ingress.yaml` | Gravitee ingress | API routing | PostgREST would sit *behind* Gravitee in a future combined setup |

Free manifest numbers in the `INTEGRATION` range (080–091): **086, 087, 088, 089**.

---

## What PostgREST is

A standalone web server (single Haskell binary, ~30 MB image, MIT licensed, [`PostgREST/postgrest`](https://github.com/PostgREST/postgrest)) that introspects a configured PostgreSQL schema and exposes its tables and views as REST endpoints. Foreign keys become embedded-resource relations (`?select=*,kommune(*)`). The server emits OpenAPI metadata at `GET /` (PostgREST 12.x, the version UIS currently pins, emits Swagger 2.0; later releases may upgrade to OpenAPI 3.x).

Properties that matter for UIS packaging:

- **Stateless** — no metadata database of its own. All state is in the target Postgres database (the schema, plus a per-app `<app>_web_anon` and `<app>_authenticator` role).
- **Tiny footprint** — ~64 Mi memory per pod under modest load; scales horizontally without coordination.
- **JWT-native auth** — validates `Authorization: Bearer <jwt>` against a configured shared secret; maps a `role` claim to `SET LOCAL ROLE`.
- **Cacheable by URL** — every request is a deterministic GET; CDN-friendly with `Cache-Control` headers.

---

## Considered alternatives

Listed for the record; all rejected during the 2026-04-27 review.

| Alternative | Why rejected |
|---|---|
| **Single shared Deployment** (one PostgREST instance pointing at one fixed database) | PostgREST is single-database; locking to one consumer blocks every other project. Multi-app use is confirmed |
| **Community Helm chart** (e.g. one of the third-party charts; no official chart exists) | For an ~80-line manifest set, a chart adds more than it removes. Community charts lag PostgREST's quarterly release cadence. Adds a Helm-repo registration to `ansible/playbooks/05-install-helm-repos.yml` |
| **Defer entirely** (each app ships its own PostgREST via ArgoCD until ≥2 consumers exist) | Duplication when the second consumer arrives. No shared verify playbook, no `services.json` entry, no shared docs page |

---

## Architectural rule

**PostgREST must point at a curated `api_v1` schema of views, never at raw application tables. Roles must be per-app prefixed.** Both rules are non-negotiable and stated in the service docs.

For application `atlas`:

```sql
CREATE SCHEMA api_v1;
CREATE ROLE atlas_web_anon NOLOGIN;
CREATE ROLE atlas_authenticator LOGIN PASSWORD '...' NOINHERIT;
GRANT atlas_web_anon TO atlas_authenticator;

CREATE VIEW api_v1.kommune AS SELECT ... FROM marts.dim_kommune;

GRANT USAGE ON SCHEMA api_v1 TO atlas_web_anon;
GRANT SELECT ON ALL TABLES IN SCHEMA api_v1 TO atlas_web_anon;
```

Postgres roles are cluster-wide, so unprefixed `web_anon` / `authenticator` would collide between projects on the shared `default/postgresql` instance. The `<app>_` prefix prevents that.

Why this rule lives in UIS docs and not "the application's problem":

- Decouples the API contract from internal models — apps can refactor `marts.*` without breaking clients.
- Keeps internal columns (debug timestamps, raw scrape fields) out of the public API.
- Enables versioning (`api_v2` lands alongside `api_v1`).
- Lets Row-Level Security policies attach to views, not raw tables, when JWT auth ships.

The schema, roles, and views are **application-side** (managed by the consumer's migrations or dbt models) — UIS's job is to deploy PostgREST and document the contract.

---

## Recommendation

Hand-rolled manifests, per-application Deployments in a shared `postgrest` namespace, anonymous-only at day 1, configured per-app via `./uis configure postgrest --app <name>`.

Rationale:
- Multi-project use is confirmed; PostgREST's single-database design means one Deployment per project anyway, so the platform should embrace that boundary from day 1.
- The configure command (PR #121, landed 2026-04-09) already creates a per-app namespace and `<prefix>-db` secret with `DATABASE_URL`. PostgREST's per-app config (`PGRST_DB_URI`, URL prefix, role prefix) fits this pattern directly — as `<app>-postgrest` secret with `PGRST_DB_URI` key.
- The architectural rule about `api_v1` views is what makes this safe, not multi-tenancy gymnastics.
- pg_graphql is split off as a separate investigation — it's a Postgres-extension policy question, not a PostgREST deployment question.

---

## Implementation notes (carried forward from a prematurely-started PLAN-001)

These were worked out while drafting an early plan; capturing them here so they survive until the plan is properly written.

### Configure handler architecture

The existing handler-dispatch model (`provision-host/uis/lib/configure.sh`) loads `configure-<service_id>.sh` from the same `lib/` directory — confirmed by `CONFIGURE_HANDLERS_DIR="${UIS_BASE}/provision-host/uis/lib"` at line 12 and the existing `lib/configure-postgresql.sh`. PostgREST should follow the same shape:

- Add `postgrest` to the configurable-services list in `_is_configurable` (`configure.sh:159`).
- Extend `run_configure`'s arg parser to accept two new optional flags: `--schema <name>` (default `api_v1`) and `--url-prefix <name>` (required for postgrest, ignored by other services).
- Create `provision-host/uis/lib/configure-postgrest.sh` (no `handlers/` subdirectory — matches the existing convention).
- The handler reads `--app`, `--database`, `--schema`, `--url-prefix` from the parsed flags. `--app` and `--database` carry over from the existing pattern; `--schema` defaults to `api_v1`; `--url-prefix` is required.

### Resource specs (initial)

| Component | CPU req | CPU limit | Mem req | Mem limit | Replicas |
|---|---|---|---|---|---|
| PostgREST instance | 50m | 500m | 64Mi | 256Mi | 2 (HA, stateless) |

`PGRST_DB_POOL=10` per pod → 20 connections per instance against `default/postgresql`. Acceptable baseline for the platform's shared Postgres; revisit if ≥4 instances run concurrently.

### Image pinning

`postgrest/postgrest:v<X.Y.Z>` pinned to a specific version (UIS practice per `INVESTIGATE-system-version-pinning.md`). Latest stable at the time of writing should be confirmed during PLAN-001 and recorded in `service-postgrest.sh` as `SCRIPT_IMAGE`.

### Ansible extra-var naming

The setup and remove playbooks receive the per-app instance via Ansible extra-var `_app_name` (underscore-prefixed to match the existing `_target` convention from [Provisioning Rules](../../../contributors/rules/provisioning.md)). The CLI dispatch in `uis-cli.sh` translates `--app <name>` into `--extra-vars "_app_name=<name>"` when invoking the playbook.

### End-to-end verification (smoke test against a real schema)

Four runnable checks against a deployed instance (e.g. `postgrest --app smoke` pointing at a tiny `api_v1.kommune` view):

```bash
# 1. OpenAPI spec (PostgREST 12.x emits Swagger 2.0; check for the swagger key)
curl -fsS http://api-smoke.localhost/ | jq .swagger              # "2.0"

# 2. Sample view returns rows
curl -fsS http://api-smoke.localhost/kommune | jq 'length > 0'   # true

# 3. Schema isolation: non-api_v1 schemas are not exposed
curl -sS -o /dev/null -w '%{http_code}\n' \
    http://api-smoke.localhost/some_internal_table              # 404

# 4. CORS preflight is honoured
curl -sS -X OPTIONS -H 'Origin: https://example.com' \
    -H 'Access-Control-Request-Method: GET' \
    http://api-smoke.localhost/kommune -i | grep -i access-control-allow-origin
```

These become the verify-playbook checks in PLAN-002.

---

## How configuration works (per-instance)

PostgREST is single-database. Each application gets its own configured instance.

### User-facing command

```bash
./uis configure postgrest --app atlas \
    --database atlas \
    --schema api_v1 \
    --url-prefix api-atlas
./uis deploy postgrest --app atlas
```

Note the **URL prefix**, not a full hostname. Traefik routes `HostRegexp` against the host header, so a single IngressRoute matches every domain the cluster is reachable on (see `manifests/085-enonic-ingressroute.yaml` for the established pattern). The user picks one subdomain label; UIS handles the rest.

### Connection model (do not reuse the application's user)

The application's existing Postgres user (e.g. `my_app` for `my_app_db`, owner-level, used by the app's own backend) is **not** what PostgREST connects as. PostgREST requires a *role-switching* pattern: the connecting role has `NOINHERIT` and zero privileges by itself, and `SET LOCAL ROLE` switches to a restricted role per request. That is why configure creates a separate `<app>_authenticator` rather than reusing the existing user.

The existing application credentials stay untouched. PostgREST gets its own user, its own password, its own Secret.

### What `configure` generates

For `--app atlas --url-prefix api-atlas` against database `atlas` (or, in your test case, `--app my_app --database my_app_db --url-prefix api-my-app`):

1. **Postgres roles** in `default/postgresql` (cluster-wide, prefixed, parallel to any existing app user):
   ```sql
   CREATE ROLE atlas_web_anon NOLOGIN;
   CREATE ROLE atlas_authenticator LOGIN PASSWORD '<generated>' NOINHERIT;
   GRANT atlas_web_anon TO atlas_authenticator;
   GRANT USAGE ON SCHEMA api_v1 TO atlas_web_anon;
   GRANT SELECT ON ALL TABLES IN SCHEMA api_v1 TO atlas_web_anon;
   ```
   `NOINHERIT` is load-bearing — it ensures the connecting role has no implicit privileges; only what `SET ROLE` explicitly switches to is granted.

2. **Kubernetes Secret** `atlas-postgrest` in namespace `postgrest`. Note port **5432** — in-cluster service port, not the host-exposed `35432`:
   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: atlas-postgrest
     namespace: postgrest
   type: Opaque
   stringData:
     PGRST_DB_URI: "postgresql://atlas_authenticator:<pw>@postgresql.default.svc.cluster.local:5432/atlas"
   ```

3. **Deployment** `atlas-postgrest` (single container, env from Secret + ConfigMap):
   ```yaml
   env:
     - name: PGRST_DB_URI
       valueFrom: { secretKeyRef: { name: atlas-postgrest, key: PGRST_DB_URI } }
     - name: PGRST_DB_SCHEMAS
       value: "api_v1"
     - name: PGRST_DB_ANON_ROLE
       value: "atlas_web_anon"
     - name: PGRST_ADMIN_SERVER_PORT
       value: "3001"
     - name: PGRST_SERVER_CORS_ALLOWED_ORIGINS
       value: "*"
   livenessProbe:  { httpGet: { path: /live,  port: 3001 } }
   readinessProbe: { httpGet: { path: /ready, port: 3001 } }
   ```

4. **Service** `atlas-postgrest` — ClusterIP on port 3000.

5. **IngressRoute** `atlas-postgrest` — single rule covering every reachable domain:
   ```yaml
   spec:
     entryPoints: [web]
     routes:
       - match: HostRegexp(`api-atlas\..+`)
         kind: Rule
         services:
           - name: atlas-postgrest
             port: 3000
   ```

### Resulting URLs (one IngressRoute, every domain Traefik knows)

| Environment | URL | How it resolves |
|---|---|---|
| Local dev | `http://api-atlas.localhost` | Rancher Desktop's localhost wildcard |
| Tailscale | `https://api-atlas.<tailnet>.ts.net` | `service-tailscale-tunnel.sh` exposes any cluster host |
| Cloudflare | `https://api-atlas.atlas.no` (or `.urbalurba.no`) | `service-cloudflare-tunnel.sh` configured for the public domain |

All three answered by the same IngressRoute via `HostRegexp(\`api-atlas\..+\`)`. No per-domain configuration in PostgREST or its IngressRoute.

### Multiple apps, no collisions

After `configure postgrest --app atlas` and `configure postgrest --app otherapp`, the `postgrest` namespace contains:

```
postgrest/
├── atlas-postgrest           (Deployment, Service, IngressRoute, Secret)
│     → Postgres roles: atlas_web_anon, atlas_authenticator
│     → matches HostRegexp(`api-atlas\..+`)
└── otherapp-postgrest         (Deployment, Service, IngressRoute, Secret)
      → Postgres roles: otherapp_web_anon, otherapp_authenticator
      → matches HostRegexp(`api-otherapp\..+`)
```

No shared state between instances. Independent deploy / undeploy / configure cycles per app.

### Removal

`./uis undeploy postgrest --app atlas` removes the per-app Deployment, Service, IngressRoute, and Secret. With `--purge`, it also drops the `atlas_web_anon` and `atlas_authenticator` Postgres roles.

### Out of scope for the configure command

Creating the `api_v1` schema and views inside the application's database is application-side work — managed by the consumer's migrations or dbt models. The service docs document the contract; UIS does not write application schemas.

---

## Next Steps

Following the [PLANS.md guidance on splitting investigations into ordered plans](../../PLANS.md):

- [x] **PLAN-001-postgrest-documentation.md** — Docs-first validation gate. Produces the service metadata, the docs page, and the Atlas review handoff. Implementation work blocked on Atlas approval.

- [ ] **PLAN-002-postgrest-deployment.md** — Package PostgREST as a UIS service per [Adding a Service](../../../contributors/guides/adding-a-service.md). This is the implementation plan that converts the documented design into a deployable service.
  - `provision-host/uis/services/integration/service-postgrest.sh` with:
    - `SCRIPT_CATEGORY="INTEGRATION"`, `SCRIPT_PRIORITY="50"` (no ordering constraint within INTEGRATION; chosen as the lowest free slot. Other INTEGRATION services: rabbitmq=60, gravitee=81, enonic=85. PostgREST's actual deploy ordering is enforced by `SCRIPT_REQUIRES="postgresql"`, not by priority within its own category)
    - `SCRIPT_REQUIRES="postgresql"` — PostgREST is unusable without it. **Dual purpose under Decision #23:** existing role is deploy-ordering; new role is configure-time precheck — when `multiInstance: true`, `configure.sh` reads `SCRIPT_REQUIRES` to decide which services' `checkCommand` must pass before dispatching to the configure handler. Both purposes use the same field; no new metadata
    - `SCRIPT_MULTI_INSTANCE="true"` (Decision #23) — drives configure precheck routing, list/status formatter behavior, and `--app` requirement on lifecycle CLI commands
    - `SCRIPT_CONSUMES_APIS="postgresql"`, `SCRIPT_PROVIDES_APIS=""` (with TODO comment per Decision #9)
    - `SCRIPT_CHECK_COMMAND` per Decision #22
    - `configurable: true` in the resulting `services.json` entry
  - `ansible/playbooks/templates/088-postgrest-config.yml.j2` — Jinja template for Deployment + Service, parametrised by `_app_name`, `_url_prefix`, `_schema`. Includes:
    - Liveness probe: HTTP GET `/live` on admin port 3001 (`PGRST_ADMIN_SERVER_PORT=3001`)
    - Readiness probe: HTTP GET `/ready` on admin port 3001
    - `PGRST_SERVER_CORS_ALLOWED_ORIGINS` env var, configurable per instance
  - `ansible/playbooks/templates/088-postgrest-ingressroute.yml.j2` — Jinja template for Traefik IngressRoute using `HostRegexp(\`{{ _url_prefix }}\..+\`)` per the [Ingress rules](../../../contributors/rules/ingress-traefik.md)
  - `ansible/playbooks/088-setup-postgrest.yml` and `088-remove-postgrest.yml` — render the templates with `lookup('template', ...)` and apply via `kubernetes.core.k8s`. Receive `_app_name` (and friends) as extra-vars from the CLI dispatch
  - `provision-host/uis/lib/configure.sh` — extend with PostgREST handling. Existing flags (`--app`, `--database`) carry over from the configure pattern; new flags `--schema <name>` and `--url-prefix <name>` need adding to `run_configure`, plus a `configure-postgrest.sh` handler at `provision-host/uis/lib/configure-postgrest.sh` (no `handlers/` subdir — matches existing `configure-postgresql.sh`). Creates `<app>_web_anon` / `<app>_authenticator` roles, writes `<app>-postgrest` secret in the `postgrest` namespace. Add `postgrest` to the configurable-services list in `_is_configurable`.
  - `provision-host/uis/lib/stacks.sh` — **not modified.** PostgREST is a standalone service, not part of any stack
  - **No** entries in static `secrets-templates/` — per-app secrets are dynamic, written by `configure` (see "Note on secrets templates" below)
  - `manifests/` — **no static manifests.** PostgREST renders per-app, so all manifests live in `ansible/playbooks/templates/` as `.j2` files
  - `website/docs/services/integration/postgrest.md` documenting the `api_v1` contract, the per-app role naming convention, the schema-reload mechanism (`NOTIFY pgrst, 'reload schema'` or `kubectl rollout restart`), and a worked configure example
  - `website/static/img/services/postgrest-logo.svg` (icon-only SVG; the upstream PNG carries the wordmark and doesn't fit the service-card layout)
  - Verification: configure + deploy a `postgrest --app test` instance against a temp schema in `default/postgresql`; `GET /` returns OpenAPI spec; sample view returns rows.

- [ ] **PLAN-003-postgrest-verify.md** — `ansible/playbooks/088-test-postgrest.yml` covering OpenAPI spec, sample-view rows, 404 on schemas outside `api_v1`, and CORS headers. Register in `VERIFY_SERVICES` and `cmd_verify` per [Adding a Service §5b](../../../contributors/guides/adding-a-service.md).

- [ ] **PLAN-004-postgrest-jwt-auth.md** *(deferred — only when a consumer actually needs an authenticated endpoint)* — Set `PGRST_JWT_SECRET` against Authentik, document the `<app>_authenticated` role and RLS pattern. Address signing-key rotation here.

  **Tutorial-1 patterns to capture when PLAN-004 opens** (see [PostgREST v14 Tutorial 1 — The Golden Key](https://docs.postgrest.org/en/v14/tutorials/tut1.html)). Day-1 (PLAN-002) follows tut0's anonymous foundation correctly; PLAN-004 picks up tut1's authenticated flow:

  - **`<app>_authenticated NOLOGIN` role** — created alongside the existing `<app>_web_anon`. Granted to `<app>_authenticator` so PostgREST can `SET LOCAL ROLE` to it per request (same pattern as the existing anon role; tut1 §"Add a Trusted User").
  - **`PGRST_JWT_SECRET`** — added to the per-app `<app>-postgrest` Secret as a second key (Decision #6 already reserves the slot). Either a shared HMAC secret (≥32 chars per tut1 §"Make a Secret") or a JWK URL pointing at Authentik's public-key endpoint — Authentik supports both shapes.
  - **`role` and `exp` JWT claims** — required claims per tut1 §"Sign a Token" and §"Add Expiration". Authentik's token configuration must emit `role: <app>_authenticated` (or a function that maps Authentik groups to per-app role names if multi-app SSO is in scope) and a non-`null` `exp`. PostgREST rejects expired tokens with `PGRST301`.
  - **`db-pre-request` hook for revocation** — tut1 bonus topic. Even with `exp`, immediate revocation matters when an Authentik session is invalidated mid-token-lifetime. Pattern: a small `auth.check_token()` PL/pgSQL function in a per-app `auth` schema that reads `current_setting('request.jwt.claims', true)::json` and raises `insufficient_privilege` on revoked tokens. Configured via `PGRST_DB_PRE_REQUEST=auth.check_token`. Whether this matters in practice depends on Authentik's session-revocation cadence vs the chosen `exp` window — if `exp ≤ 5 min`, the hook may be unnecessary overhead.
  - **Per-request RLS policies** — RLS attaches to views/tables, gates rows by `current_setting('request.jwt.claims')` values (e.g. `claims.email`, `claims.user_id`). PostgREST's `SET LOCAL ROLE` only changes the active role; RLS expressions on the views are how per-user filtering happens. PLAN-004 should worked-example one Atlas-style scenario (e.g. "an NGO admin sees only their own organisation's rows").
  - **Signing-key rotation** (Decision #14) — when Authentik rotates its signing key, PostgREST's `PGRST_JWT_SECRET` (or JWK cache) must update. Two flavours: HMAC rotation (regenerate secret in both Authentik and the PostgREST Secret, rolling restart) vs JWK URL (PostgREST polls the URL and picks up new keys automatically — cleanest).

  Day-1 (PLAN-002) does not implement any of the above. Adding `PGRST_JWT_SECRET` to the `<app>-postgrest` Secret without configuring authenticated roles would not break PostgREST — it accepts JWTs only when the env var is set — but doing it incrementally is the right shape.

- [ ] **PLAN-005-multi-instance-formatters.md** *(follow-up to PLAN-002)* — Full per-instance reporting in `./uis status` (one row per configured instance with ready/desired counts) for any service with `multiInstance: true`. Touches the shared status/list formatters across every service, so deliberately split out from PLAN-002 to keep that diff narrow. Closes the UX wart from Decision #22 by making postgrest's "0 instances" state legible instead of misleading.

- [ ] **INVESTIGATE-pg-graphql.md** *(separate)* — Whether to expose `api_v1` as GraphQL via the `pg_graphql` Postgres extension. This is a Postgres-extension policy decision, not a PostgREST one.

---

## Files to Modify (when PLAN-001 starts)

Per the file map in [Adding a Service](../../../contributors/guides/adding-a-service.md):

- `provision-host/uis/services/integration/service-postgrest.sh`
- `provision-host/uis/lib/configure-postgrest.sh` — per-service configure handler
- `provision-host/uis/lib/configure.sh` — extend `run_configure` with `--schema` / `--url-prefix` flags; add `postgrest` to `_is_configurable`
- `ansible/playbooks/088-setup-postgrest.yml`
- `ansible/playbooks/088-remove-postgrest.yml`
- `ansible/playbooks/templates/088-postgrest-config.yml.j2` — Jinja template for Deployment + Service
- `ansible/playbooks/templates/088-postgrest-ingressroute.yml.j2` — Jinja template for Traefik IngressRoute
- `ansible/playbooks/088-test-postgrest.yml` *(PLAN-002)*
- `provision-host/uis/manage/uis-cli.sh` — pass `--app <name>` through to setup / remove / status playbooks
- `provision-host/uis/templates/uis.extend/enabled-services.conf.default` — commented entry
- `website/docs/services/integration/postgrest.md` — Docusaurus service page following [Documentation Standards](../../../contributors/rules/documentation.md)
- `website/static/img/services/postgrest-logo.svg` — service logo. Icon-only SVG (no wordmark) so it fits the square service-card layout. The upstream PNG (`https://raw.githubusercontent.com/PostgREST/postgrest/main/static/postgrest.png`) carries the full wordmark and is too wide for the card; if a future contributor wants the original, UIS still accepts PNG for several other services (`loki-logo.png`, `openmetadata-logo.png`, `pgadmin-logo.png`). Filename must match `SCRIPT_LOGO="postgrest-logo.svg"` in `service-postgrest.sh`.
- `website/sidebars.ts` — register the new doc page under the integration category

**Contributor documentation updates (per Decision #21 — new template-rendering convention):**

PostgREST is the first UIS service to use Ansible Jinja templates for per-instance manifest rendering. Every existing service applies static `manifests/*.yaml` via `kubernetes.core.k8s: src: ...`, so the contributor docs assume that pattern. PLAN-001 must update them to cover the multi-instance / rendered-template path so future contributors know which pattern to follow:

- `website/docs/contributors/guides/adding-a-service.md` — add a section on multi-instance services. Cover: when to choose rendered templates over static manifests (any service taking `--app <name>`); the `ansible/playbooks/templates/<NNN>-<service>-*.yml.j2` location; the `lookup('template', ...)` + `kubernetes.core.k8s: definition:` pattern; the extra-vars contract (`_app_name`, `_url_prefix`, `_schema`, etc.); how `--app` flows from CLI → setup playbook → template.
- `website/docs/contributors/rules/provisioning.md` — document the new convention alongside the existing `_target` extra-var rule. Underscore-prefixed extra-vars now include `_app_name` and per-service variants for multi-instance services.
- `website/docs/contributors/rules/kubernetes-deployment.md` — clarify the split: `manifests/` for static single-instance YAML, `ansible/playbooks/templates/` for rendered per-instance YAML.

**Note on secrets templates:** Unlike most UIS services, PostgREST does **not** add entries to `provision-host/uis/templates/secrets-templates/00-common-values.env.template` or `00-master-secrets.yml.template`. Per-app secrets (`<app>-postgrest`) are created dynamically by `./uis configure postgrest --app <name>` and stored in the `postgrest` namespace. The static-template flow does not fit a service that has N instances, each with its own generated password.

Application-side (out of scope for UIS PRs, documented in the service page for consumers): the `api_v1` schema, `<app>_web_anon` / `<app>_authenticator` roles, and view definitions.
