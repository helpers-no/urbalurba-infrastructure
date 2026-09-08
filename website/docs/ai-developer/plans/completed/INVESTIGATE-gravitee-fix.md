# Investigate: Deploy Gravitee APIM 4.11 on PostgreSQL with a minimal footprint

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: Deploy Gravitee API Management on the UIS local cluster as a working API gateway with admin UI, using **PostgreSQL** as the management store and **no Elasticsearch / no Redis / no MongoDB**, on the smallest sustainable resource footprint.

**Last Updated**: 2026-04-30

**Related**:
- [STATUS-service-migration.md](./STATUS-service-migration.md) - Gravitee was the only unverified service at end of migration; this investigation supersedes that history.
- [Adding a Service](../../../contributors/guides/adding-a-service.md) - Service definition, playbook, ingress, secrets, and test conventions.

**Depends on**: PostgreSQL (manifest `042`), Traefik IngressRoute CRDs, UIS secrets generation. **Does NOT depend on** MongoDB, Elasticsearch, or Redis.

---

## Why this is a fresh investigation

The previous Gravitee setup in the repo (`090-setup-gravitee.yml` + `090-gravitee-config.yaml` + `091-gravitee-ingress.yaml` + `service-gravitee.sh`) was last touched over a year ago, never reliably worked, was pinned to APIM **4.8.4** (now ~9 months stale), and assumed **MongoDB** as the metadata store. Both the Helm chart layout and the supported backend matrix have moved enough that patching the existing files line-by-line is more work than starting from a current baseline.

This investigation supersedes any prior Gravitee plan in the repo. The implementation will replace the existing service files rather than amend them.

---

## Investigation Result

Gravitee APIM 4.11 supports **PostgreSQL via the JDBC repository plugin** as a first-class drop-in for MongoDB for the management/config store. The PostgreSQL JDBC driver is bundled in the official APIM distribution; configuration is documented alongside MongoDB with no "experimental" caveats. A working install on a single-node cluster is achievable with:

- **4 APIM pods** (Management API, Management UI / Console, Developer Portal, API Gateway)
- **PostgreSQL** for the management store, reusing the cluster's existing shared `postgresql` service
- **No Elasticsearch** (analytics dashboards disabled — accepted trade-off)
- **No Redis** (rate-limit policies disabled — accepted trade-off)
- **No MongoDB**

Baseline footprint at default sizing is roughly **2 CPU / 4 GiB** across the four pods, tunable down on a laptop. The official `graviteeio/apim` Helm chart (currently at version 4.11.x, lives in `gravitee-io/gravitee-api-management/helm/`) defaults all bundled subcharts (`mongodb-replicaset`, `elasticsearch`) to `enabled: false` and exposes external-DB configuration via standard values.

**Recommendation**: Replace all four current Gravitee files with a minimal PostgreSQL-backed deployment. Treat existing `GRAVITEE_MONGODB_*` keys in the secrets template as obsolete and emit `GRAVITEE_POSTGRES_*` instead. Keep the chart at the latest stable 4.11.x.

---

## Current State (what's in the repo today)

| File | Status | Action in implementation |
|------|--------|--------------------------|
| `provision-host/uis/services/integration/service-gravitee.sh` | Exists. `SCRIPT_NAMESPACE=default`, `SCRIPT_REQUIRES=""`, `SCRIPT_REMOVE_PLAYBOOK=""`, `SCRIPT_CHECK_COMMAND` references namespace `gravitee`. Internally inconsistent. | **Rewrite** — namespace `gravitee`, requires `postgresql`, set remove playbook, fix health selector. |
| `ansible/playbooks/090-setup-gravitee.yml` | Exists, 465 lines, deploys APIM 4.8.4 into `default`, uses raw `kubectl`/`helm`, includes a hardcoded personal Tailscale hostname, mixed health checks and deploy logic. | **Rewrite** from scratch around the standard UIS playbook pattern. |
| `ansible/playbooks/090-remove-gravitee.yml` | Missing. | **Create.** |
| `manifests/090-gravitee-config.yaml` | Exists. Helm values pinned at 4.8.4. Disables bundled MongoDB and ES. Embeds a literal MongoDB URI with credentials in two places. Enables chart-managed Kubernetes ingress. | **Rewrite** — JDBC/PostgreSQL backend via secret resolver, chart ingress disabled, no literal credentials. |
| `manifests/091-gravitee-ingress.yaml` | Exists. Traefik `IngressRoute` in `default` namespace. Uses `Host()` (localhost-only). Generic hostnames `api.localhost`, `portal.localhost`. | **Rewrite** — `gravitee` namespace, `HostRegexp(...)` patterns, `gravitee*` prefixed hostnames. |
| `provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template` | Has `GRAVITEE_MONGODB_DATABASE_*` keys in the `default` namespace secret (currently unused after this rewrite). Also has `GRAVITEE_ADMIN_*`, `GRAVITEE_ENCRYPTION_KEY`, `GRAVITEE_TEST_*`. | **Replace** the `GRAVITEE_MONGODB_*` keys with `GRAVITEE_POSTGRES_*`. Move the runtime-secret block into a new `gravitee/urbalurba-secrets`. Keep admin/encryption keys. |
| `provision-host/uis/templates/secrets-templates/00-common-values.env.template` | No first-class Gravitee variables — values are derived inside `00-master-secrets.yml.template` from `MONGODB_ROOT_PASSWORD`. | **Add** `GRAVITEE_POSTGRES_USER`, `GRAVITEE_POSTGRES_PASSWORD`, `GRAVITEE_POSTGRES_DATABASE` as first-class variables (mirrors the OpenWebUI pattern). |
| `manifests/040-mongodb-config.yaml` and `ansible/playbooks/040-setup-mongodb.yml` | Both contain Gravitee-specific MongoDB user/database bootstrap. | **Remove** the Gravitee-specific blocks once Gravitee no longer uses MongoDB. Tracked as a follow-up cleanup; not blocking. |

---

## Architecture for the Fix

### Components and their role

The "Resource ask" column shows the **laptop-tuned override** UIS sets in `manifests/090-gravitee-config.yaml` — not the chart defaults. Default chart values ship higher (≈500m / 1Gi requested per pod across all four). Override numbers below are starting points; tune during Phase 4.

| Component | Required? | What it does | Resource ask (laptop-tuned override) |
|-----------|-----------|--------------|--------------------------------------|
| **Management API** | Yes | REST backend powering the Console and Portal; owns Liquibase migrations | requests 200m / 768Mi, limits 1000m / 1.5Gi |
| **Management UI (Console)** | Yes | Admin SPA for API designers | requests 50m / 128Mi, limits 200m / 256Mi |
| **Developer Portal UI** | Yes | Public catalog SPA for API consumers | requests 50m / 128Mi, limits 200m / 256Mi |
| **API Gateway** | Yes | The actual proxy enforcing API definitions; reads API definitions from JDBC | requests 200m / 512Mi, limits 1000m / 1Gi |
| **PostgreSQL** | Shared, cluster-wide | Management/config store via JDBC plugin | (already running) |
| Elasticsearch | **Skipped (v1)** | Analytics, log search, dashboards. Not running ES means the analytics tab in Console is empty. Gateway works. Console works. APIs are managed normally. | n/a |
| Redis | **Skipped (v1)** | Rate-limit policy store, response cache. Not running Redis means rate-limit policies cannot be applied (`ratelimit.type: none`). Everything else works. | n/a |
| MongoDB | **Removed** | Replaced by PostgreSQL. | n/a |

Sustainable baseline at these overrides: **~500m CPU / 1.5 GiB requested** combined across the four pods, with a per-cluster cap of ~2.4 CPU / 3 GiB if all four pods burst to limits simultaneously. Default chart values would land closer to ~2 CPU / 4 GiB requested.

### Data flow

```
                         ┌─────────────────────────────┐
                         │        Traefik              │
                         │  HostRegexp(`gravitee*\..+`)│
                         └──┬───────┬──────┬──────┬────┘
                            │       │      │      │
              gravitee\..+  │       │      │      │  gravitee-portal\..+
                            ▼       ▼      ▼      ▼
                          ┌─────┐ ┌─────┐ ┌──────┐ ┌──────┐
                          │ UI  │ │ API │ │  GW  │ │PORTAL│
                          │ SPA │ │ REST│ │proxy │ │ SPA  │
                          └──┬──┘ └──┬──┘ └──┬───┘ └───┬──┘
                             │       │      │         │
                             │       └──┬───┘         │
                             │          │             │
                             │   ┌──────▼──────┐      │
                             │   │  postgresql │      │
                             │   │  (default)  │      │
                             │   │ graviteedb  │      │
                             │   └─────────────┘      │
                             │                        │
                             └────────[ talks to mgmt-api ]
```

The Console UI and Developer Portal UI both call the Management API over HTTP using the cluster-internal service name. The Gateway syncs API definitions from the management database directly. Nothing else is in the picture.

### What we lose by skipping ES and Redis

This is the explicit trade-off list, so a future contributor knows what to switch on if they need it:

- **Empty analytics view in Console** — no per-API request counts, latency graphs, or status-code distributions. APIs still serve traffic; Gravitee just doesn't aggregate it.
- **No rate-limiting / quota policies** — applying any rate-limit policy in the Console will succeed at design time but silently fail at runtime (or error out, depending on the chart's behavior with `ratelimit.type: none`). Document this in the contributor docs.
- **No response caching policy** — same shape as rate-limiting, depends on Redis.
- **No log search in Console** — gateway request logs go to stdout. `kubectl logs` is the only way to search them.

All four are first-class production features; none are required to validate that "Gravitee is deployed and the gateway proxies traffic."

### Hostname strategy

| Component | HostRegexp pattern | Purpose |
|-----------|--------------------|---------|
| Management Console | ``HostRegexp(`gravitee\..+`)`` | Admin UI |
| Management API | ``HostRegexp(`gravitee-api\..+`)`` | Backend API for Console + Portal |
| API Gateway | ``HostRegexp(`gravitee-gw\..+`)`` | Runtime API proxy endpoint |
| Developer Portal | ``HostRegexp(`gravitee-portal\..+`)`` | Public/internal API catalog |

All four work across `*.localhost`, `*.<tailnet>.ts.net`, and Cloudflare-tunneled domains without per-domain manifest edits. Public (no Authentik forward auth) for the first fix.

---

## Decisions

| # | Topic | Decision |
|---|-------|----------|
| 1 | Service model | Single shared Gravitee instance per UIS cluster, not multi-instance. |
| 2 | Namespace | Run all APIM components in namespace `gravitee`. Leave shared PostgreSQL in `default`. |
| 3 | Deployment mechanism | Use the official `graviteeio/apim` Helm chart at the **latest 4.11.x** patch (currently 4.11.3). Pin the chart version explicitly; bumps are separate plans. |
| 4 | Management store | **PostgreSQL via JDBC repository plugin.** No MongoDB. |
| 5 | Elasticsearch | **Skipped.** Analytics disabled. Re-evaluate when there is a real need. |
| 6 | Redis | **Skipped.** Rate-limit and response-cache policies disabled. Re-evaluate when policies are actually configured. |
| 7 | Routing | Disable chart-managed Kubernetes ingress. Use UIS-owned Traefik `IngressRoute` resources in `091-gravitee-ingress.yaml`. |
| 8 | Hostnames | `gravitee`, `gravitee-api`, `gravitee-gw`, `gravitee-portal` via `HostRegexp`. |
| 9 | Auth | No Authentik forward-auth in v1. Gravitee has its own admin login. SSO is a follow-up plan. |
| 10 | Dependencies | `SCRIPT_REQUIRES="postgresql"`. |
| 11 | Secrets | No credentials in tracked manifests. JDBC connection assembled from `gravitee/urbalurba-secrets` at runtime via the chart's `secret://` resolver if it works for `management.jdbc.*`, otherwise via `extraEnvs` references. (Open check #2.) |
| 12 | Database bootstrap | The Gravitee setup playbook creates `graviteedb` + `gravitee_user` on PostgreSQL using the platform's `postgresql` admin connection. This is the same pattern UIS uses for OpenWebUI, OpenMetadata, and Backstage on Postgres. No coupling lives inside the PostgreSQL manifest. |
| 13 | Resource overrides | Set explicit `resources.requests` and `resources.limits` per pod in `090-gravitee-config.yaml` (laptop-tuned). Don't rely on chart defaults. |
| 14 | Verification | First prove deploy/undeploy works manually via `./uis deploy gravitee` and `./uis undeploy gravitee`. Add `090-test-gravitee.yml` after deploy is stable. |
| 15 | Existing MongoDB-side bootstrap | Out of scope for this plan. The Gravitee-specific blocks in `040-mongodb-config.yaml` and `040-setup-mongodb.yml` become dead code; remove in a follow-up cleanup PR after the new flow is verified. |
| 16 | SPA → Management API URL | The Console UI and Developer Portal SPA both run in the user's browser and need the **external** URL of the Management API (e.g. `http://gravitee-api.localhost`), not the cluster-internal service. With chart-managed ingress disabled, UIS owns this configuration. The Helm values must set `ui.env.MANAGEMENT_URL` (or equivalent — exact key per Open Check #3) and the equivalent on `portal`. **This is the #1 deploy-killer for the chart-ingress-disabled approach** — the Console SPA cannot authenticate without it. |
| 17 | CORS | Default chart values handle CORS automatically when chart ingress is enabled. With chart ingress **disabled** (Decision #7), the Management API must explicitly allow the Console and Portal external origins via the chart's CORS configuration (or a Traefik middleware on the IngressRoute). Verify this works for `*.localhost` patterns. |

---

## Recommended Target Shape

### Service metadata — `service-gravitee.sh`

```bash
#!/bin/bash
# service-gravitee.sh - Gravitee API Management

# === Service Metadata (Required) ===
SCRIPT_ID="gravitee"
SCRIPT_NAME="Gravitee APIM"
SCRIPT_DESCRIPTION="API gateway and management platform"
SCRIPT_CATEGORY="INTEGRATION"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="090-setup-gravitee.yml"
SCRIPT_MANIFEST="090-gravitee-config.yaml,091-gravitee-ingress.yaml"
SCRIPT_CHECK_COMMAND="kubectl get pods -n gravitee -l app.kubernetes.io/instance=gravitee-apim --no-headers 2>/dev/null | grep -qE '\\s(Running|Completed)\\s'"
SCRIPT_REMOVE_PLAYBOOK="090-remove-gravitee.yml"
SCRIPT_REQUIRES="postgresql"
SCRIPT_PRIORITY="50"

# === Deployment Details (Optional) ===
# Pinned at the latest stable 4.11.x as of 2026-04-30. The graviteeio/apim
# chart follows APIM versioning. Bump deliberately; verify Phase 4 again.
SCRIPT_IMAGE="graviteeio/apim:4.11.3"  # informational; chart pulls per-component images
SCRIPT_NAMESPACE="gravitee"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Component"
SCRIPT_TYPE="service"
SCRIPT_OWNER="platform-team"

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="A platform service that runs Gravitee API Management with PostgreSQL as the metadata store and no Elasticsearch/Redis dependencies."
SCRIPT_SUMMARY="Gravitee APIM is an open-source API gateway and management platform with admin Console, Developer Portal, and runtime API gateway. UIS deploys APIM 4.11 with PostgreSQL as the management store via the JDBC repository plugin (no MongoDB). Elasticsearch and Redis are not deployed; analytics dashboards and rate-limit policies are disabled. Suitable for laptop-scale development clusters."
SCRIPT_LOGO="gravitee-logo.svg"
SCRIPT_WEBSITE="https://www.gravitee.io"
SCRIPT_TAGS="api-gateway,api-management,gravitee,postgresql"
SCRIPT_DOCS="/docs/services/integration/gravitee"
```

The exact label selector for `SCRIPT_CHECK_COMMAND` should be verified after the first successful deploy (Open Check #1). The chart's actual instance label may differ from `gravitee-apim`.

### First-class secret variables — `00-common-values.env.template`

Add (mirrors the existing OpenWebUI pattern):

```bash
# Gravitee APIM (PostgreSQL backend)
GRAVITEE_POSTGRES_USER=gravitee_user
GRAVITEE_POSTGRES_PASSWORD=${DEFAULT_DATABASE_PASSWORD}
GRAVITEE_POSTGRES_DATABASE=graviteedb
```

### Namespace secret — `00-master-secrets.yml.template`

Replace the existing `GRAVITEE_MONGODB_DATABASE_*` block in the `default` namespace secret with a new `gravitee` namespace secret:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: gravitee
---
apiVersion: v1
kind: Secret
metadata:
  name: urbalurba-secrets
  namespace: gravitee
type: Opaque
stringData:
  # PostgreSQL backend (replaces MongoDB completely)
  GRAVITEE_POSTGRES_HOST: "postgresql.default.svc.cluster.local"
  GRAVITEE_POSTGRES_PORT: "5432"
  GRAVITEE_POSTGRES_USER: "${GRAVITEE_POSTGRES_USER}"
  GRAVITEE_POSTGRES_PASSWORD: "${GRAVITEE_POSTGRES_PASSWORD}"
  GRAVITEE_POSTGRES_DATABASE: "${GRAVITEE_POSTGRES_DATABASE}"
  GRAVITEE_POSTGRES_JDBC_URL: "jdbc:postgresql://postgresql.default.svc.cluster.local:5432/${GRAVITEE_POSTGRES_DATABASE}"
  # Admin / encryption (preserved from existing template)
  GRAVITEE_ADMIN_EMAIL: "${DEFAULT_ADMIN_EMAIL}"
  GRAVITEE_ADMIN_PASSWORD: "${DEFAULT_ADMIN_PASSWORD}"
  GRAVITEE_ENCRYPTION_KEY: "${GRAVITEE_ENCRYPTION_KEY}"
```

The `default` namespace's `urbalurba-secrets` block keeps `GRAVITEE_ADMIN_*` and `GRAVITEE_ENCRYPTION_KEY` *only if* they are needed by the bootstrap flow — otherwise drop them to avoid duplicate sources of truth. The `GRAVITEE_MONGODB_*` keys are removed entirely.

### Helm values — `manifests/090-gravitee-config.yaml`

Top-level shape (only the parts that change vs the chart defaults; verify exact keys against the 4.11.x `values.yaml` during implementation):

```yaml
# Pinned chart version handled in the Ansible Helm task, not here.
# This file is the values overrides only.

# Disable bundled subcharts — both default to false in 4.11, but we
# set them explicitly so the intent is auditable.
mongodb-replicaset:
  enabled: false
elasticsearch:
  enabled: false
es:
  enabled: false

# Management store: PostgreSQL via JDBC plugin
management:
  type: jdbc
  jdbc:
    # Resolver shape preferred. Confirm during implementation that
    # secret:// works for the JDBC fields specifically. If not, fall
    # back to api/portal/gateway extraEnvs referencing the secret.
    url: "secret://kubernetes/urbalurba-secrets:GRAVITEE_POSTGRES_JDBC_URL"
    username: "secret://kubernetes/urbalurba-secrets:GRAVITEE_POSTGRES_USER"
    password: "secret://kubernetes/urbalurba-secrets:GRAVITEE_POSTGRES_PASSWORD"
    # Liquibase auto-runs schema migrations on first start.
    liquibase: true

# Rate-limit: disabled — no Redis, no MongoDB
ratelimit:
  type: none

# Analytics: disabled — no Elasticsearch
analytics:
  enabled: false

# Disable chart-managed ingress for all four components.
# UIS routes are defined in 091-gravitee-ingress.yaml.
api:
  ingress:
    management:
      enabled: false
    portal:
      enabled: false
  # Resource overrides — laptop-tuned. Adjust during Phase 4 testing.
  resources:
    requests: { cpu: "200m", memory: "768Mi" }
    limits:   { cpu: "1000m", memory: "1.5Gi" }

gateway:
  ingress:
    enabled: false
  resources:
    requests: { cpu: "200m", memory: "512Mi" }
    limits:   { cpu: "1000m", memory: "1Gi" }

ui:
  ingress:
    enabled: false
  baseURL: "/"
  # CRITICAL (Decision #16): Console UI is an SPA; it calls the Management
  # API from the user's browser using the EXTERNAL hostname, not the
  # cluster-internal service. Without this, login fails immediately.
  # Exact key in 4.11 is one of: ui.env.MANAGEMENT_URL, ui.constants,
  # or a configmap mount — verify against the chart's values.yaml
  # (Open Check #3). The value should be the IngressRoute hostname
  # for the Management API:
  env:
    MANAGEMENT_URL: "http://gravitee-api.localhost"
  resources:
    requests: { cpu: "50m",  memory: "128Mi" }
    limits:   { cpu: "200m", memory: "256Mi" }

portal:
  ingress:
    enabled: false
  # Same concern as ui: the Portal SPA calls the Management API from
  # the user's browser. Verify the exact 4.11 key (likely portal.env
  # or portal.constants).
  env:
    PORTAL_API_URL: "http://gravitee-api.localhost"
  resources:
    requests: { cpu: "50m",  memory: "128Mi" }
    limits:   { cpu: "200m", memory: "256Mi" }

# CORS (Decision #17): with chart-managed ingress disabled, the Management
# API must explicitly allow the Console and Portal external origins.
# Most likely set on api.http.api.management.cors / api.http.api.portal.cors
# in 4.11 — verify exact path. For laptop dev, allow * pattern:
api:
  cors:
    allowOrigin: "*"
    allowMethods: "OPTIONS, GET, POST, PUT, DELETE"
    allowHeaders: "*"
```

If `secret://kubernetes/urbalurba-secrets:KEY` resolution doesn't work for the JDBC fields specifically, the fallback is to use `extraEnvs` on the components that need DB access. Both the Management API **and the Gateway** read API definitions from the management database in 4.x, so both need the secret values:

```yaml
api:
  extraEnvs:
    - name: GRAVITEE_MANAGEMENT_JDBC_URL
      valueFrom: { secretKeyRef: { name: urbalurba-secrets, key: GRAVITEE_POSTGRES_JDBC_URL } }
    - name: GRAVITEE_MANAGEMENT_JDBC_USERNAME
      valueFrom: { secretKeyRef: { name: urbalurba-secrets, key: GRAVITEE_POSTGRES_USER } }
    - name: GRAVITEE_MANAGEMENT_JDBC_PASSWORD
      valueFrom: { secretKeyRef: { name: urbalurba-secrets, key: GRAVITEE_POSTGRES_PASSWORD } }

gateway:
  extraEnvs:
    - name: GRAVITEE_MANAGEMENT_JDBC_URL
      valueFrom: { secretKeyRef: { name: urbalurba-secrets, key: GRAVITEE_POSTGRES_JDBC_URL } }
    - name: GRAVITEE_MANAGEMENT_JDBC_USERNAME
      valueFrom: { secretKeyRef: { name: urbalurba-secrets, key: GRAVITEE_POSTGRES_USER } }
    - name: GRAVITEE_MANAGEMENT_JDBC_PASSWORD
      valueFrom: { secretKeyRef: { name: urbalurba-secrets, key: GRAVITEE_POSTGRES_PASSWORD } }
```

UI and Portal are static SPAs; they do not connect to PostgreSQL and do not need these env vars.

### IngressRoute — `manifests/091-gravitee-ingress.yaml`

```yaml
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: gravitee-console
  namespace: gravitee
spec:
  entryPoints: [web]
  routes:
    - match: HostRegexp(`gravitee\..+`)
      kind: Rule
      services:
        - name: gravitee-apim-ui
          port: 8002
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: gravitee-management-api
  namespace: gravitee
spec:
  entryPoints: [web]
  routes:
    - match: HostRegexp(`gravitee-api\..+`)
      kind: Rule
      services:
        - name: gravitee-apim-api
          port: 83
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: gravitee-gateway
  namespace: gravitee
spec:
  entryPoints: [web]
  routes:
    - match: HostRegexp(`gravitee-gw\..+`)
      kind: Rule
      services:
        - name: gravitee-apim-gateway
          port: 82
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: gravitee-portal
  namespace: gravitee
spec:
  entryPoints: [web]
  routes:
    - match: HostRegexp(`gravitee-portal\..+`)
      kind: Rule
      services:
        - name: gravitee-apim-portal
          port: 8003
```

Service names and ports must be verified against the actual chart output (Open Check #1). The values above match the 4.11.x chart's documented defaults but may not be byte-exact.

### Setup playbook — `ansible/playbooks/090-setup-gravitee.yml`

Should follow the same shape used by other UIS service playbooks (Authentik, OpenWebUI, OpenMetadata):

1. **Display deployment context** — namespace, chart version, target Postgres host.
2. **Ensure namespace** `gravitee`.
3. **Verify dependency**: PostgreSQL is reachable; the `urbalurba-secrets` Secret exists in the `gravitee` namespace and carries the required JDBC keys.
4. **Bootstrap database**: create `graviteedb` and `gravitee_user` on the platform's `postgresql` service (idempotent, using `CREATE ROLE ... IF NOT EXISTS` and `CREATE DATABASE ... IF NOT EXISTS`-equivalent SQL via psql against postgresql-0). Use `no_log: true` for password handling.
5. **Ensure Helm repo** `graviteeio` exists and is up to date.
6. **Install/upgrade** `graviteeio/apim` at the pinned version using `kubernetes.core.helm`, with values from `manifests/090-gravitee-config.yaml`.
7. **Apply** `091-gravitee-ingress.yaml` via `kubernetes.core.k8s`.
8. **Wait** for Management API, Gateway, UI, Portal Deployments to reach Available.
9. **Health probe** internal endpoints from inside the cluster (Management API `/management/health`, Gateway `/_node/health`).
10. **Print** concise access URLs (`http://gravitee.localhost`, etc.) and admin credentials hint.

### Remove playbook — `ansible/playbooks/090-remove-gravitee.yml`

1. **Uninstall** the `gravitee-apim` Helm release.
2. **Remove** the four IngressRoute objects.
3. **Leave** PVCs and the `gravitee/urbalurba-secrets` Secret intact by default (re-deploy works without re-bootstrap).
4. **Optional `--purge` extra-var** drops the database, role, secret, namespace. Off by default.

---

## Proposed Implementation Plan

Single plan file: `PLAN-gravitee-postgresql-deployment.md`. Suggested phases:

### Phase 1: Replace service metadata and secrets

**Status: partially complete** (secret template work landed during the investigation cycle on 2026-04-30; documented here so the implementer doesn't re-do it).

Already in the working tree:

- [x] `GRAVITEE_POSTGRES_USER`, `GRAVITEE_POSTGRES_PASSWORD`, `GRAVITEE_POSTGRES_DATABASE` added as first-class variables to `00-common-values.env.template`.
- [x] New `gravitee/urbalurba-secrets` block in `00-master-secrets.yml.template` containing `GRAVITEE_POSTGRES_HOST/PORT/USER/PASSWORD/DATABASE/JDBC_URL`, `GRAVITEE_ADMIN_EMAIL/PASSWORD`, `GRAVITEE_ENCRYPTION_KEY`.
- [x] Old `GRAVITEE.IO API MANAGEMENT SYSTEM` block removed from the `default` namespace section (admin email/password, encryption key, the stale `GRAVITEE_TEST_*` Cloudflare-tunnel subdomain stubs).
- [x] **Transition stub** (option-b decision): the three `GRAVITEE_MONGODB_DATABASE_*` keys remain in the MongoDB section of the `default` namespace secret with a deprecation comment, because `040-setup-mongodb.yml` still validates their presence on `./uis deploy mongodb`. They are removed in Phase 5 alongside the MongoDB-side bootstrap.

Still to do:

- [ ] Rewrite `provision-host/uis/services/integration/service-gravitee.sh` per the target shape.
- [ ] Run `./uis secrets generate` and dry-run-apply the resulting secrets to confirm the new gravitee namespace block renders cleanly.

### Phase 2: Replace Helm values and ingress

- [ ] Rewrite `manifests/090-gravitee-config.yaml` per the target shape (chart 4.11.x, JDBC backend, ratelimit none, analytics off, chart ingress disabled, laptop-tuned resources).
- [ ] Rewrite `manifests/091-gravitee-ingress.yaml` (`gravitee` namespace, four `HostRegexp` IngressRoutes).
- [ ] Verify the chart's actual service names and ports against the values file (Open Check #1).

### Phase 3: Rewrite deploy and remove playbooks

- [ ] Rewrite `090-setup-gravitee.yml` from scratch using the standard UIS playbook pattern.
- [ ] Create `090-remove-gravitee.yml`.
- [ ] Use `kubernetes.core.helm` and `kubernetes.core.k8s` modules instead of raw `helm`/`kubectl` shell calls.
- [ ] All secret-handling tasks set `no_log: true`.
- [ ] No personal hostnames, no debug-only output blocks.

### Phase 4: End-to-end deploy validation

- [ ] On a fresh cluster, `./uis deploy postgresql` then `./uis deploy gravitee`.
- [ ] Verify all four pods reach Ready in namespace `gravitee`.
- [ ] Verify the four IngressRoutes resolve and serve content.
- [ ] Log into the admin Console at `http://gravitee.localhost`. Create a sample API. Hit it via the Gateway.
- [ ] `./uis undeploy gravitee`. Re-run `./uis deploy gravitee`. Confirm idempotency.
- [ ] Remove the cluster, redeploy from scratch end-to-end. This must work without manual intervention.

### Phase 5: Cleanup and add automated verification

- [ ] Remove the Gravitee-specific blocks from `040-mongodb-config.yaml` and `040-setup-mongodb.yml` (they are now dead code — they no longer serve any consumer).
- [ ] Remove the three transition-stub keys (`GRAVITEE_MONGODB_DATABASE_NAME/USER/PASSWORD`) from the MongoDB section of `00-master-secrets.yml.template` and the deprecation comment block above them. These were kept in option-b to preserve `./uis deploy mongodb` validation; once the MongoDB-side bootstrap is gone, the validation reference goes too.
- [ ] Update `troubleshooting/debug-mongodb.sh` to drop the three `GRAVITEE_MONGODB_DATABASE_*` lookups (lines ~59–61). Replace with a comment indicating Gravitee no longer uses MongoDB.
- [ ] Grep the repo for any remaining `GRAVITEE_MONGODB` reference and remove (target: zero matches).
- [ ] Add `090-test-gravitee.yml` covering: pods Ready, IngressRoutes resolve, Management API health endpoint returns 200, Gateway `/_node/health` returns 200, Console root returns 200, Portal root returns 200.
- [ ] Register Gravitee in the `./uis test-all` flow.
- [ ] Update integration testing docs to remove the "Gravitee always skipped" note.

---

## Validation Commands

```bash
# Secrets path
./uis secrets generate
kubectl apply --dry-run=client -f .uis.secrets/generated/kubernetes/kubernetes-secrets.yml

# Cluster baseline
./uis deploy postgresql

# Deploy
./uis deploy gravitee

# Verify Kubernetes objects
kubectl get pods -n gravitee
kubectl get svc -n gravitee
kubectl get ingressroute -n gravitee
kubectl get secret urbalurba-secrets -n gravitee -o jsonpath='{.data}' | jq 'keys'

# Verify the database side
PGPW=$(kubectl get secret postgresql -n default -o jsonpath='{.data.postgres-password}' | base64 -d)
kubectl exec -n default postgresql-0 -- bash -c \
  "PGPASSWORD='$PGPW' psql -U postgres -c '\l graviteedb'"
kubectl exec -n default postgresql-0 -- bash -c \
  "PGPASSWORD='$PGPW' psql -U postgres -c '\du gravitee_user'"

# Smoke
curl -fsS http://gravitee.localhost/         # admin Console SPA
curl -fsS http://gravitee-api.localhost/management/health
curl -fsS http://gravitee-gw.localhost/_node/health
curl -fsS http://gravitee-portal.localhost/  # developer portal SPA

# Lifecycle
./uis undeploy gravitee
```

Once `090-test-gravitee.yml` exists:

```bash
./uis verify gravitee
./uis test-all
```

---

## Acceptance Criteria

- [ ] `./uis list` shows Gravitee in namespace `gravitee` with `SCRIPT_REQUIRES="postgresql"` and a populated `SCRIPT_REMOVE_PLAYBOOK`.
- [ ] `./uis deploy gravitee` deploys APIM 4.11.x with all four Deployments reaching Available. Gravitee itself does not deploy or depend on MongoDB / Elasticsearch / Redis — none appear in the `gravitee` namespace, and no Gravitee component holds connections to them. (UIS may run those services for *other* consumers; this criterion is about Gravitee's dependencies, not the cluster as a whole.)
- [ ] PostgreSQL contains a `graviteedb` database owned by `gravitee_user`. Liquibase migrations have run cleanly on first start (visible in Management API pod logs).
- [ ] No tracked manifest contains a literal Gravitee password, JDBC URL with credentials, or admin password.
- [ ] All four URLs (`http://gravitee.localhost`, `gravitee-api.localhost`, `gravitee-gw.localhost`, `gravitee-portal.localhost`) resolve and return the expected SPA / health response.
- [ ] An admin can log in to the Console with `${DEFAULT_ADMIN_EMAIL}` / `${DEFAULT_ADMIN_PASSWORD}`, create a sample API, deploy it, and proxy a request through the Gateway successfully.
- [ ] `./uis undeploy gravitee` removes the Helm release and IngressRoutes; PVCs and the secret remain. `./uis deploy gravitee` afterward succeeds without re-bootstrap.
- [ ] A full `./uis undeploy gravitee && ./uis deploy gravitee` cycle passes on a cluster that already has Gravitee state (idempotent re-deploy).
- [ ] On a fresh cluster, the entire `./uis deploy postgresql && ./uis deploy gravitee` chain works end-to-end without manual intervention.

---

## Files to Modify in the Implementation Plan

| File | Change |
|------|--------|
| `provision-host/uis/services/integration/service-gravitee.sh` | Rewrite per target shape. |
| `ansible/playbooks/090-setup-gravitee.yml` | Replace contents with standard UIS playbook pattern. |
| `ansible/playbooks/090-remove-gravitee.yml` | Create. |
| `manifests/090-gravitee-config.yaml` | Replace contents — JDBC backend, no ES/Redis, chart ingress disabled, laptop-tuned resources. |
| `manifests/091-gravitee-ingress.yaml` | Replace contents — `gravitee` namespace, four `HostRegexp` IngressRoutes. |
| `provision-host/uis/templates/secrets-templates/00-common-values.env.template` | Add `GRAVITEE_POSTGRES_*` variables. |
| `provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template` | Replace `GRAVITEE_MONGODB_*` block with `gravitee/urbalurba-secrets` block. |
| `ansible/playbooks/090-test-gravitee.yml` | Create after Phase 4 succeeds. |
| `manifests/040-mongodb-config.yaml` | **Phase 5**: remove Gravitee-specific init logic (dead code after switch). |
| `ansible/playbooks/040-setup-mongodb.yml` | **Phase 5**: remove Gravitee-specific verification (dead code after switch). |
| Integration testing docs | **Phase 5**: remove the "Gravitee always skipped" note. |
| `website/static/img/services/gravitee-logo.svg` | Add if not already present (referenced by `SCRIPT_LOGO`). |

---

## Open Checks Before Implementation

1. **Verify chart service names, ports, and instance label.** Run `helm template graviteeio/apim --version 4.11.3` (or current) on a clean working tree to print exact resource names. Update `091-gravitee-ingress.yaml` and `service-gravitee.sh` `SCRIPT_CHECK_COMMAND` accordingly.
2. **Verify `secret://kubernetes/urbalurba-secrets:KEY` resolution** for `management.jdbc.url`, `management.jdbc.username`, `management.jdbc.password`. **Verification method:** do a 5-minute throwaway deploy with one JDBC field set via `secret://`; if the Management API pod logs show `unable to resolve secret reference` or similar, fall back to `extraEnvs` on `api` and `gateway` (per the Helm values fallback section). The Gravitee secret resolver is documented for some fields but not universally; confirm against 4.11 docs *and* actual pod logs.
3. **Confirm Console UI and Developer Portal external-URL configuration shape in 4.11.x** (Decision #16 is load-bearing). The Console SPA and Portal SPA both run in the user's browser and need to know the *external* URL of the Management API. Historically this was `ui.env.MANAGEMENT_URL` / `ui.constants` / a configmap mount; the exact 4.11 key needs to be looked up against the chart's `values.yaml`. **Same check for `portal.env.PORTAL_API_URL` (or equivalent).** Without this, the Console fails to authenticate immediately on first load.
4. **Confirm CORS configuration shape on the Management API for 4.11.x** (Decision #17). With chart ingress disabled, UIS owns CORS. Verify whether the chart key is `api.cors.*`, `api.http.api.management.cors.*`, or somewhere else, and whether `*` allow-origin works for `*.localhost` patterns or requires explicit listing.
5. **Confirm health endpoint paths on APIM 4.11.x components.** Probably:
   - Gateway: `/_node/health`
   - Management API: `/management/health` or `/management/_health`
   - UI/Portal: standard SPA root.

   Verify against the deployed chart in Phase 4 and update the playbook health probes accordingly.
6. **Liquibase migration ownership and ordering** (more pointed than "does it auto-run"). When the chart deploys mgmt-api + gateway simultaneously and both have JDBC connections to the same database, who owns running Liquibase? If both attempt migrations on first start, you risk a Liquibase lock conflict or schema corruption. Verify the chart enforces "only the management API runs migrations" (typical APIM pattern) or document the wait/retry behavior. Inspect Management API and Gateway pod startup logs side-by-side in Phase 4.
7. **Verify behavior when applying a rate-limit policy with `ratelimit.type: none`.** Confirm whether Console disables the policy UI, accepts but warns, or silently saves a non-functional policy. Document the result for contributors.
8. **Choose a chart pin policy.** APIM moves quarterly; the chart at 4.11.x is current today, 4.12 lands ~June 2026. Decide whether to track latest chart automatically or pin and bump deliberately. Recommended: pin and bump as separate plans, same convention as PostgreSQL/MongoDB/Elasticsearch.
9. **Persistence (PVCs).** The chart likely creates PVCs for plugin storage, license cache, etc. Inventory these during Phase 4 and decide what `./uis undeploy gravitee --purge` should remove vs preserve.
10. **Image pull source / rate limits.** APIM images come from `graviteeio/*` on Docker Hub (not GHCR). Anonymous pulls have IP-level rate limits — fine on a single dev laptop, worth noting for CI/multi-cluster scenarios.
11. **Chart upgrade-in-place behavior.** When 4.12 lands and `SCRIPT_IMAGE` is bumped, `./uis deploy gravitee` does a `helm upgrade`. Will Liquibase auto-migrate the existing schema? Will any existing encrypted data require the same `GRAVITEE_ENCRYPTION_KEY` to remain readable? Document the upgrade/rollback story before the first 4.12 bump.
12. **TLS / external HTTPS callback URLs.** When Gravitee is reached via Cloudflare tunnel (HTTPS externally, HTTP into Traefik), do any Gravitee features (OAuth callbacks, portal links) rely on the request scheme? Verify Gravitee respects `X-Forwarded-Proto` or hard-code the scheme in the SPA URL config above.

---

## Next Steps

- [ ] Promote this investigation to `PLAN-gravitee-postgresql-deployment.md` in `plans/active/`.
- [ ] Resolve Open Check #1 (chart resource names) before writing `091-gravitee-ingress.yaml` to avoid a broken first deploy.
- [ ] Phase 1–4 in order. Phase 5 cleanup gates on a clean Phase 4 sign-off, not before.
- [ ] Validate on a freshly reset cluster — old MongoDB-backed PVCs and secrets must not be in the picture.
