# Investigate: OpenMetadata Deployment

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: Determine the best approach for deploying OpenMetadata as a UIS platform service

**Last Updated**: 2026-03-10

---

## Questions to Answer

1. What is OpenMetadata and what does it provide?
2. Which existing UIS services can OpenMetadata reuse (MySQL, Elasticsearch)?
3. Does OpenMetadata need Airflow, or can it use the Kubernetes Jobs executor instead?
4. What category and manifest number should it use?
5. What are the resource requirements — is it feasible on a developer laptop?
6. Should we use the official Helm chart or custom manifests?

---

## Background Research

### What is OpenMetadata?

OpenMetadata is an open-source metadata platform for **data discovery**, **data observability**, and **data governance**. It provides:

- **Data Discovery** — search across all data assets (databases, dashboards, pipelines, ML models)
- **Data Lineage** — column-level lineage tracking across systems
- **Data Quality** — profiling and quality checks
- **Data Governance** — policies, glossaries, classification, ownership
- **Collaboration** — conversations, tasks, announcements tied to data assets
- **100+ connectors** — integrates with databases, warehouses, BI tools, etc.

Created by the founders of Apache Hadoop, Apache Atlas, and Uber Databook. Maintained by Collate.

### Architecture

OpenMetadata has a 4-component architecture:

| Component | Description |
|---|---|
| **API Server** | Java/Dropwizard REST API. Central component — all others interact through it. |
| **UI** | TypeScript/React SPA served by the API server process. |
| **Metadata Store** | MySQL or PostgreSQL. Stores entities as JSON, relationships in a graph-like table. |
| **Search Engine** | Elasticsearch or OpenSearch. Indexes metadata for discovery. |
| **Ingestion Framework** | Python-based, 100+ connectors. Runs as Airflow DAGs or Kubernetes Jobs. |

No Redis, Kafka, Neo4j, or message queues required.

### Docker Images

| Image | Purpose | Ports |
|---|---|---|
| `docker.getcollate.io/openmetadata/server` | API server + UI | 8585, 8586 |
| `docker.getcollate.io/openmetadata/ingestion` | Airflow-based ingestion (if using Airflow) | 8080 |
| `docker.getcollate.io/openmetadata/ingestion-base` | Base image for K8s ingestion jobs | — |

### Version Selection

**Selected version: OpenMetadata 1.12.1** (Feb 24, 2025 — marked "Latest" on GitHub)

| Component | Version | Notes |
|---|---|---|
| OpenMetadata Server | 1.12.1 | Docker image: `docker.getcollate.io/openmetadata/server:1.12.1` |
| Helm chart (`openmetadata`) | 1.12.1 | Pin with `--version 1.12.1` in playbook |
| Elasticsearch | 9.3.0 | Already deployed in UIS (manifest 060) |
| PostgreSQL | 12+ | Already deployed in UIS (manifest 042) |
| Kubernetes | >= 1.24 | UIS meets this requirement |

**Why 1.12.1:**
- Latest stable release, marked "Latest" on GitHub
- Requires ES 9.3.0 — exactly what UIS now has deployed
- Introduces Kubernetes native orchestrator as the recommended ingestion approach (no Airflow needed)
- The 1.11.x line (latest: 1.11.13) still uses ES 8.x — would not benefit from our ES upgrade

### Official Helm Charts

Repository: https://github.com/open-metadata/openmetadata-helm-charts

Two charts:

**1. `openmetadata`** (main application) — **this is the one we deploy**
- Deploys only the OpenMetadata server
- Expects database and search engine to already exist (external)
- No sub-chart dependencies
- Kubernetes 1.24+

**2. `openmetadata-dependencies`** (backing services) — **not needed**
- Conditionally deploys MySQL, OpenSearch, and Airflow
- Each can be individually disabled via `mysql.enabled`, `opensearch.enabled`, `airflow.enabled`
- Sub-charts: Bitnami MySQL 14.0.2, Apache Airflow 1.18.0, OpenSearch 3.3.2
- We skip this entirely — UIS already provides PostgreSQL and Elasticsearch, and we use K8s Jobs instead of Airflow

### Resource Requirements

Production recommendations:

| Component | CPU | Memory | Storage |
|---|---|---|---|
| OpenMetadata Server | 4 vCPU | 16 GiB | 100 GiB |
| Database | 4 vCPU | 16 GiB | 30-100 GiB |
| Search engine | 2 vCPU | 8 GiB | 100 GiB |

Development/minimal (from Helm defaults):
- Server: JVM heap 1G
- OpenSearch: 256M request / 2G limit, JVM heap 1G
- MySQL: 50Gi storage

**Total minimum for dev**: ~4-6 CPU cores, 8-12 GB RAM across all components. This is heavy for a developer laptop.

---

## Existing UIS Services That OpenMetadata Can Reuse

| OpenMetadata needs | UIS already has | Reusable? |
|---|---|---|
| **Database: MySQL 8.0+ or PostgreSQL 12+** | Both MySQL (manifest 043) and PostgreSQL (manifest 042) in `default` namespace | Yes — **PostgreSQL preferred** (UIS standard). Create `openmetadata_db` database on existing instance. |
| **Elasticsearch 9.x (minimum 9.0.0)** | Elasticsearch 9.3.0 in `default` namespace (manifest 060, pinned) | Yes — version matches. ES 9.3.0 deployed and verified. |
| **Airflow** | Not deployed | Not available — but can use K8s Jobs executor instead |

### PostgreSQL reuse (preferred)

OpenMetadata supports both MySQL and PostgreSQL. **UIS prefers PostgreSQL** — it is the primary database service (manifest 042, Helm chart `bitnami/postgresql`, port 5432). OpenMetadata needs a database called `openmetadata_db`. The setup playbook would create this database on the existing PostgreSQL instance.

The Helm chart is configured for PostgreSQL by setting:
```yaml
database:
  host: postgresql.default.svc.cluster.local
  port: 5432
  driverClass: org.postgresql.Driver
  dbScheme: postgresql
  databaseName: openmetadata_db
```

### Elasticsearch reuse — RESOLVED

UIS Elasticsearch has been upgraded to **9.3.0** (pinned via `imageTag: "9.3.0"` in `060-elasticsearch-config.yaml`). This matches OpenMetadata 1.12.1's requirement of ES 9.x (minimum 9.0.0).

The ES config (`xpack.security.enabled: false`, HTTP protocol, port 9200) is exactly what OpenMetadata needs. No changes required.

```yaml
elasticsearch:
  host: elasticsearch-master.default.svc.cluster.local
  port: 9200
  scheme: http
  searchType: elasticsearch
```

### Airflow — not needed (K8s orchestrator is recommended)

Starting with OpenMetadata 1.12, the **Kubernetes native orchestrator is the recommended approach**, eliminating the need for Apache Airflow. No functionality is lost — the K8s orchestrator supports all ingestion features (scheduled, on-demand, all 100+ connectors).

| Capability | Airflow | K8s Orchestrator |
|---|---|---|
| Run ingestion pipelines | Yes | Yes |
| Scheduled ingestion (CronJobs) | Yes | Yes |
| On-demand ingestion | Yes | Yes |
| 100+ connectors | Yes | Yes |
| Pipeline monitoring from UI | Yes | Yes |
| **Infrastructure complexity** | High (ReadWriteMany PVCs, deps chart) | Low (native K8s Jobs) |

The K8s orchestrator has an optional **OMJob Operator** (uses CRDs) for production. If cluster policies restrict CRDs, set `useOMJobOperator: false` to fall back to plain K8s Jobs.

Configuration:
- `pipelineServiceClientConfig.type: "k8s"` in Helm values
- Ingestion runs as short-lived K8s Jobs using `docker.getcollate.io/openmetadata/ingestion-base` image
- No Airflow deployment, no ReadWriteMany volumes, no additional infrastructure

---

## Deployment Approach

### Option A: Official Helm Charts (deps chart disabled, main chart only)

Use the official `openmetadata` Helm chart. Disable the `openmetadata-dependencies` chart entirely. Point the main chart at existing UIS services:

```yaml
# Point to existing PostgreSQL (UIS preferred database)
# Credentials come from urbalurba-secrets in the openmetadata namespace
database:
  host: postgresql.default.svc.cluster.local
  port: 5432
  driverClass: org.postgresql.Driver
  dbScheme: postgresql
  databaseName: openmetadata_db
  # auth.password referenced via secretKeyRef — see Secrets Integration section

# Point to existing Elasticsearch
elasticsearch:
  host: elasticsearch-master.default.svc.cluster.local
  port: 9200
  scheme: http
  searchType: elasticsearch

# Use K8s Jobs instead of Airflow
pipelineServiceClientConfig:
  type: "k8s"
```

**Pros:**
- Official, maintained chart
- Follows the same Helm + Ansible pattern as other UIS services
- Easy to upgrade when new versions are released

**Cons:**
- Chart may have assumptions about its deps chart that need overriding
- Less control over exact resource settings

### Option B: Custom manifests (no Helm)

Deploy OpenMetadata server as a Deployment + Service + IngressRoute using custom manifests. Configure via environment variables and ConfigMaps.

**Pros:**
- Full control over every detail
- No Helm chart assumptions to work around

**Cons:**
- More work to maintain
- Harder to upgrade
- Reinvents what the official chart already does

### Recommendation: Option A

Use the official `openmetadata` Helm chart with Ansible playbook, same as PostgreSQL, Redis, and other Helm-based services.

---

## Category and Manifest Number

OpenMetadata is a data governance/analytics tool. It fits in the **ANALYTICS** category (300-399).

Existing ANALYTICS manifests:
- 300: Spark config
- 310-311: JupyterHub config + ingress
- 320-321: Unity Catalog deployment + ingress

**Proposed: 340** for OpenMetadata (leaves room between Unity Catalog and OpenMetadata).

---

## Ingress

Following the UIS pattern: `HostRegexp(`openmetadata\..+`)` routing to port 8585.

Access at `http://openmetadata.localhost`.

---

## Resource Concerns

OpenMetadata's production requirements (4 vCPU + 16 GiB for the server alone) are heavy for a developer laptop. However:

- The dev/minimal settings use JVM heap of 1G for the server
- Reusing existing PostgreSQL and Elasticsearch avoids deploying additional services
- Skipping Airflow (using K8s Jobs) saves significant resources
- The server is idle most of the time in a dev environment

**Estimated UIS resource usage** (reusing existing services, no Airflow):

| Component | CPU request | Memory request |
|---|---|---|
| OpenMetadata Server | 500m | 1.5Gi |
| (PostgreSQL — shared, already running) | — | — |
| (Elasticsearch — shared, already running) | — | — |
| **Total new resources** | **~500m** | **~1.5Gi** |

This is manageable on a developer laptop.

---

## Dependencies

OpenMetadata requires PostgreSQL and Elasticsearch to be running first.

```
SCRIPT_REQUIRES="postgresql elasticsearch"
```

The setup playbook should:
1. Verify PostgreSQL and Elasticsearch are running
2. Create the `openmetadata_db` database on the existing PostgreSQL
3. Deploy the OpenMetadata Helm chart
4. Deploy the IngressRoute
5. Wait for the server to be ready

---

## Secrets Integration

OpenMetadata must use the UIS secrets system. All credentials flow through the three-stage pipeline:

```
Templates (in git)  →  .uis.secrets/secrets-config/ (per-machine)  →  .uis.secrets/generated/ (applied to cluster)
```

### What needs to be added

**1. Variables in `provision-host/uis/templates/secrets-templates/00-common-values.env.template`:**

```bash
# OpenMetadata
OPENMETADATA_DB_PASSWORD=${DEFAULT_DATABASE_PASSWORD}
```

OpenMetadata reuses `DEFAULT_DATABASE_PASSWORD` — same as PostgreSQL, Unity Catalog, and all other database services.

**2. Secret block in `provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template`:**

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: openmetadata
---
apiVersion: v1
kind: Secret
metadata:
  name: urbalurba-secrets
  namespace: openmetadata
type: Opaque
stringData:
  OPENMETADATA_DATABASE_URL: "postgresql://postgres:${PGPASSWORD}@${PGHOST}:5432/openmetadata_db"
  OPENMETADATA_DATABASE_USER: "postgres"
  OPENMETADATA_DATABASE_PASSWORD: "${PGPASSWORD}"
```

**3. Defaults in `provision-host/uis/templates/default-secrets.env`:**

No new defaults needed — `DEFAULT_DATABASE_PASSWORD` already has a default value (`LocalDevDB456`).

### How the setup playbook uses secrets

Following the Unity Catalog pattern:

1. **Retrieve PostgreSQL password** from the `default` namespace secret:
   ```bash
   kubectl get secret urbalurba-secrets -n default -o jsonpath='{.data.PGPASSWORD}' | base64 -d
   ```

2. **Create the database** on the existing PostgreSQL:
   ```bash
   kubectl exec -n default <postgres-pod> -- \
     bash -c "PGPASSWORD='<password>' createdb -h postgresql.default -U postgres openmetadata_db"
   ```

3. **Helm values reference the secret** via environment variables:
   ```yaml
   env:
     - name: DB_USER_PASSWORD
       valueFrom:
         secretKeyRef:
           name: urbalurba-secrets
           key: OPENMETADATA_DATABASE_PASSWORD
   ```

### Password restrictions

Do NOT use `!`, `$`, `` ` ``, `\`, or `"` in passwords — Bitnami Helm charts pass passwords through bash.

---

## Similarity to Unity Catalog

Unity Catalog (already in UIS) is a similar data governance tool that:
- Runs in its own namespace (`unity-catalog`)
- Depends on PostgreSQL (existing service)
- Has a web UI routed through Traefik

OpenMetadata follows the same pattern — depends on PostgreSQL + Elasticsearch, both already available in UIS.

---

## Proposed Files

| Piece | File |
|-------|------|
| Service definition | `provision-host/uis/services/analytics/service-openmetadata.sh` (must include website metadata — `uis-docs.sh` generates JSON from these for the docs website) |
| Setup playbook | `ansible/playbooks/340-setup-openmetadata.yml` |
| Remove playbook | `ansible/playbooks/340-remove-openmetadata.yml` |
| Config / Helm values | `manifests/340-openmetadata-config.yaml` |
| IngressRoute | `manifests/341-openmetadata-ingressroute.yaml` |
| Secrets variables | Add to `provision-host/uis/templates/secrets-templates/00-common-values.env.template` |
| Secrets manifest | Add `openmetadata` namespace block to `provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template` |
| Enabled services | Add `openmetadata` to `provision-host/uis/config/enabled-services.conf` |
| Documentation | `website/docs/services/analytics/openmetadata.md` |
| Sidebar entry | Add `openmetadata` to `website/sidebars.ts` under the analytics category |

---

## Helm Repository

The OpenMetadata Helm repo (`https://open-metadata.github.io/openmetadata-helm-charts/`) is not currently registered in UIS. Following the UIS convention, the setup playbook adds its own Helm repo (each playbook is responsible for its own Helm repo). The playbook will add the repo before installing the chart:

```yaml
- name: Add OpenMetadata Helm repository
  kubernetes.core.helm_repository:
    name: open-metadata
    repo_url: https://open-metadata.github.io/openmetadata-helm-charts/
```

---

## RBAC for K8s Jobs Executor

The K8s orchestrator creates Jobs and CronJobs in the cluster. The OpenMetadata server pod needs RBAC permissions to manage these resources. The Helm chart may handle this automatically, but this needs verification during implementation. If not, the setup playbook must create:

- A ServiceAccount for OpenMetadata
- A Role/ClusterRole with permissions for Jobs, CronJobs, Pods, and Pod logs
- A RoleBinding/ClusterRoleBinding

---

## Next Steps

- [x] Verify Elasticsearch version compatibility with OpenMetadata → **ES 9.3.0 deployed and verified. Matches OpenMetadata 1.12.1 requirement.**
- [x] Decide how to resolve ES version mismatch → **Upgrade UIS ES to 9.3.0. Completed — see [PLAN-elasticsearch-upgrade.md](../completed/PLAN-elasticsearch-upgrade.md)**
- [x] Determine if OpenMetadata needs Authentik SSO integration → **No — skip Authentik for initial setup. Keep it simple.**
- [x] Select OpenMetadata version → **1.12.1 (latest stable, requires ES 9.3.0, supports K8s orchestrator)**
- [x] Confirm no functionality lost without Airflow → **K8s orchestrator is the recommended approach in 1.12. All ingestion features supported.**
- [x] Test minimal resource settings on a dev laptop → **Verified: 500m CPU, 1.5Gi memory works on dev laptop**
- [x] Create PLAN-openmetadata-deployment.md with implementation phases → **Done: [PLAN-openmetadata-deployment.md](PLAN-openmetadata-deployment.md)**
