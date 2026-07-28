---
title: Temporal
sidebar_label: Temporal
---

# Temporal

Durable workflow orchestration engine

| | |
|---|---|
| **Category** | Integration |
| **Deploy** | `./uis deploy temporal` |
| **Undeploy** | `./uis undeploy temporal` |
| **Depends on** | [postgresql](../databases/postgresql.md) |
| **Required by** | None |
| **Helm chart** | `temporal/temporal` (pinned to 1.6.0 — server 1.31.2, UI 2.52.0) |
| **Default namespace** | `temporal` |

## What It Does

Temporal is a **durable execution** platform. You write workflows as ordinary code — Go, TypeScript, Python, Java, .NET or PHP — and Temporal records every state transition in a database. If the process running your workflow crashes, gets redeployed, or waits three days for a human approval, the workflow resumes exactly where it left off with its local variables intact.

Key capabilities:

- **Durable workflows** — code survives crashes, restarts, and deploys; no saga/state-machine boilerplate
- **Automatic retries** — activity retry policies, timeouts, and backoff declared in code
- **Long timers** — `sleep(30 days)` is a normal thing to write
- **Visibility** — list and query running/completed workflows from the Web UI or the CLI
- **Web UI** at `temporal.localhost` — inspect workflow histories, terminate, reset, replay

Typical uses: order/payment pipelines, user onboarding flows, data pipelines with retries, scheduled jobs that must not be lost, anything currently held together by a cron job plus a status column.

### PostgreSQL-only — no Elasticsearch, no Cassandra

Temporal needs two datastores: **history** (workflow state) and **visibility** (the searchable index behind `workflow list` and the UI). Many Temporal deployments put visibility in Elasticsearch. UIS does not — since Temporal 1.20, advanced visibility works on PostgreSQL 12+, so both stores live in the **shared UIS PostgreSQL**:

| Store | Database | Purpose |
|-------|----------|---------|
| History (`default`) | `temporal` | Workflow state and event history |
| Visibility | `temporal_visibility` | Searchable workflow index |

That keeps a laptop cluster small: no Elasticsearch, no Cassandra, and no second PostgreSQL. The setup playbook creates the `temporal` role and both databases inside the existing `postgresql` service in the `default` namespace, then the chart's schema Job applies the Temporal SQL schema.

## Deploy

```bash
./uis deploy postgresql   # dependency
./uis deploy temporal
```

Access after deploy:

| What | URL |
|------|-----|
| Web UI (browser) | `http://temporal.localhost` |
| HTTP API (browser / apps outside the cluster) | `http://temporal-api.localhost/api/v1/namespaces` |
| gRPC frontend (from inside the cluster) | `temporal-frontend.temporal.svc.cluster.local:7233` |
| gRPC frontend (from the host machine) | `./uis expose temporal` → `localhost:37233` |

The Temporal namespace `default` (3-day retention) is created at deploy time, so a worker can connect immediately.

## Verify

```bash
# Full E2E test suite (health, datastores, HTTP API, workflow round-trip, UI, routing)
./uis verify temporal

# Manual checks
kubectl get pods -n temporal
kubectl exec -n temporal deploy/temporal-admintools -- temporal operator cluster health
kubectl exec -n temporal deploy/temporal-admintools -- temporal workflow list
```

## Configuration

Temporal configuration is in `manifests/086-temporal-config.yaml`. Key settings:

| Setting | Value | Notes |
|---------|-------|-------|
| History store | `postgres12` → `temporal` | Shared `postgresql.default` service |
| Visibility store | `postgres12` → `temporal_visibility` | Advanced visibility on PostgreSQL, no Elasticsearch |
| `numHistoryShards` | `4` | **Cannot be changed after the first deploy** without wiping the `temporal` database. Matches the `temporalio/auto-setup` default; the chart default of 512 is a production number. |
| Frontend | gRPC `7233`, HTTP `7243` | Service `temporal-frontend` |
| Web UI | `8080` | Service `temporal-web` |
| Replicas | 1 per component | frontend, history, matching, worker, web, admintools |
| Temporal namespace | `default`, 3d retention | Created by the chart's namespace Job |

### Components

| Pod | Role |
|-----|------|
| `temporal-frontend` | gRPC/HTTP API — clients and workers connect here |
| `temporal-history` | Owns workflow history shards |
| `temporal-matching` | Task queue matching |
| `temporal-worker` | Temporal's own internal system workers |
| `temporal-web` | Web UI |
| `temporal-admintools` | `temporal` / `tctl` CLIs, used by `./uis verify temporal` |

### Secrets

| Variable | File | Purpose |
|----------|------|---------|
| `TEMPORAL_POSTGRES_USER` | `.uis.secrets/secrets-config/00-common-values.env.template` | PostgreSQL role Temporal logs in as |
| `TEMPORAL_POSTGRES_PASSWORD` | same file | Password for that role |
| `TEMPORAL_POSTGRES_DATABASE` | same file | History database name (`temporal`) |
| `TEMPORAL_POSTGRES_VISIBILITY_DATABASE` | same file | Visibility database name (`temporal_visibility`) |

They land in the `urbalurba-secrets` Secret in the **`temporal` namespace**, together with `TEMPORAL_ADDRESS` and `TEMPORAL_NAMESPACE` for applications. The Helm chart reads the password directly out of that Secret (`existingSecret` / `secretKey`), so no credential is ever written into a manifest.

Read them back with:

```bash
kubectl get secret urbalurba-secrets -n temporal -o jsonpath='{.data.TEMPORAL_POSTGRES_USER}' | base64 -d
kubectl get secret urbalurba-secrets -n temporal -o jsonpath='{.data.TEMPORAL_ADDRESS}' | base64 -d
```

To change them: edit `00-common-values.env.template`, then `./uis secrets generate`, `./uis secrets apply`, and re-deploy Temporal (the setup playbook rotates the PostgreSQL role password to match).

### Connecting a worker

Workers running in the cluster mount `urbalurba-secrets` from the `temporal` namespace, or hard-code the in-cluster address:

```yaml
env:
  - name: TEMPORAL_ADDRESS
    value: temporal-frontend.temporal.svc.cluster.local:7233
  - name: TEMPORAL_NAMESPACE
    value: default
```

Example (TypeScript SDK):

```ts
import { NativeConnection, Worker } from '@temporalio/worker';

const connection = await NativeConnection.connect({
  address: process.env.TEMPORAL_ADDRESS,   // temporal-frontend.temporal.svc.cluster.local:7233
});

const worker = await Worker.create({
  connection,
  namespace: process.env.TEMPORAL_NAMESPACE ?? 'default',
  taskQueue: 'my-queue',
  workflowsPath: require.resolve('./workflows'),
  activities,
});

await worker.run();
```

For development from the host machine (or a devcontainer), port-forward the gRPC frontend:

```bash
./uis expose temporal         # binds localhost:37233 -> svc/temporal-frontend:7233
./uis expose temporal --stop
```

### Key Files

| File | Purpose |
|------|---------|
| `manifests/086-temporal-config.yaml` | Helm values (PostgreSQL-only persistence, resources, components) |
| `manifests/087-temporal-ingressroute.yaml` | Traefik routes: `temporal.*` → Web UI, `temporal-api.*` → HTTP API |
| `ansible/playbooks/086-setup-temporal.yml` | Deployment playbook (creates role + databases, installs chart, health checks) |
| `ansible/playbooks/086-remove-temporal.yml` | Removal playbook (keeps the databases unless `--purge`) |
| `ansible/playbooks/086-test-temporal.yml` | E2E verification playbook (`./uis verify temporal`) |

## Undeploy

```bash
# Removes the deployment, keeps the temporal and temporal_visibility databases
./uis undeploy temporal

# Drops both databases and the temporal role — all workflow history is gone permanently
./uis undeploy temporal --purge
```

Temporal has no PVC of its own in UIS: all of its state lives in the shared PostgreSQL. "Keeping the data" therefore means leaving those two databases alone.

## Troubleshooting

**Deploy fails with "TEMPORAL_POSTGRES_PASSWORD not found":**

The secret has not been applied to the cluster yet:

```bash
./uis secrets generate
./uis secrets apply
./uis deploy temporal
```

If `secrets generate` does not produce the key, your `.uis.secrets/secrets-config/00-common-values.env.template` predates Temporal — copy the `TEMPORAL_*` block from the shipped template into it.

**Deploy fails with "PostgreSQL is required for Temporal":**

```bash
./uis deploy postgresql
./uis deploy temporal
```

**Helm install times out on the schema hook:**

The chart runs `temporal-sql-tool setup-schema` as a pre-install Job. Look at it:

```bash
kubectl get jobs -n temporal
kubectl logs -n temporal job/temporal-schema --all-containers
```

A permission error here usually means the `temporal` role cannot create tables in `public` — re-running `./uis deploy temporal` re-applies the `GRANT ALL ON SCHEMA public` step.

**Pods restart with "unable to connect to database":**

The role password in PostgreSQL and the one in `urbalurba-secrets` have drifted (usually after a secret rotation without a re-deploy). Fix with `./uis secrets apply` followed by `./uis deploy temporal` — the playbook runs `ALTER ROLE … WITH PASSWORD` to bring them back in sync.

**`temporal workflow list` returns nothing but workflows exist:**

That is the visibility store, not the history store. Check that the `temporal_visibility` schema was applied (`kubectl get jobs -n temporal`) and that the config still names both stores:

```bash
kubectl get cm temporal-config -n temporal -o jsonpath='{.data.config_template\.yaml}' | head -30
```

**Web UI loads but shows "Unable to connect":**

The UI talks to `temporal-frontend:7233`. Check the frontend is Ready and SERVING:

```bash
kubectl get pods -n temporal -l app.kubernetes.io/component=frontend
kubectl exec -n temporal deploy/temporal-admintools -- temporal operator cluster health
```

## Learn More

- [Official Temporal documentation](https://docs.temporal.io/)
- [Temporal Helm chart](https://github.com/temporalio/helm-charts)
- [Self-hosted visibility on SQL databases](https://docs.temporal.io/self-hosted-guide/visibility)
- [Temporal CLI reference](https://docs.temporal.io/cli)
