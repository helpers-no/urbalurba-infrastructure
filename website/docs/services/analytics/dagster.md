---
title: Dagster
sidebar_label: Dagster
---

# Dagster

The platform's data-asset orchestrator: scheduling, lineage, freshness and dbt-native pipelines.

| | |
|---|---|
| **Category** | Analytics |
| **Deploy** | `./uis deploy dagster` |
| **Undeploy** | `./uis undeploy dagster` |
| **Verify** | `./uis verify dagster` |
| **Depends on** | PostgreSQL |
| **Required by** | None — applications register themselves as tenants |
| **Helm chart** | `dagster/dagster` **pinned to `1.13.19`** |
| **Default namespace** | `dagster` |
| **UI** | `http://dagster.localhost` — internal only, no authentication |

## Dagster or Temporal?

UIS ships **two** orchestrators, deliberately. They are not alternatives, and
picking the wrong one is expensive later.

| | **Temporal** | **Dagster** |
|---|---|---|
| Orchestrates | **processes** | **data assets** |
| You write | imperative workflow code | a declarative asset graph |
| Core guarantee | durable execution — a workflow resumes mid-step after a crash | lineage and freshness — what produced this table, from what, how stale it is |
| Reach for it when | a long-lived business process must survive failure | tables, files or models must be built, kept fresh and traced |
| Has no concept of | an asset, lineage, freshness, backfill | durable mid-step resumption |

**Rule of thumb:** if the thing you care about is a *process completing*, that is
Temporal. If it is a *dataset being correct and current*, that is Dagster.

Running a data pipeline on Temporal means rebuilding Dagster's asset graph, dbt
integration and freshness tracking by hand. Running a durable business process on
Dagster means discovering that a run pod dying mid-step does not resume.

:::info The platform rule
**UIS carries at most one orchestrator per shape.** Temporal owns durable
code-first execution; Dagster owns data-asset pipelines. Airflow, Prefect, Argo
Workflows and Kubernetes CronJobs are all the *data* shape and would duplicate
Dagster. A third orchestrator needs a shape neither covers — preferring its UI is
not a shape.
:::

## What It Does

Dagster orchestrates **assets** rather than tasks. You declare the tables, files
and models your pipelines produce; Dagster schedules them, tracks what produced
what, notices when something is stale, and re-materialises it.

The parts that matter operationally:

- **Webserver** — the run and asset UI. How a failed refresh gets diagnosed.
- **Daemon** — runs the schedules and the run queue. **The load-bearing
  component.** A Dagster install without a healthy daemon is a UI over nothing.
- **Run pods** — one ephemeral pod per materialisation, capped by the platform.

## Registering an application (the tenant contract)

**UIS ships the orchestrator. Applications register themselves.** A fresh install
has *no* code locations, and `./uis verify dagster` reporting `Code locations
registered: 0` is expected, not a fault.

A **code location** is how an application hands its asset definitions to the
platform: a container image the application builds and publishes, which Dagster
loads over gRPC.

### Where the declaration lives

Code locations are declared **per installation**, in:

```
.uis.extend/dagster-code-locations.yaml
```

:::warning Do not edit the platform manifest
`manifests/360-dagster-config.yaml` is UIS *product* configuration and ships to
every installation. Putting a code location there would send one application's
config to installations that have never heard of it. The extend file is
per-installation — the same relationship `prometheus-targets.yaml` has to
Prometheus, and `external-services.yaml` to the database.

**An application's own installer should write its entry here.**
:::

```yaml
code_locations:
  - name: myapp-data
    image: ghcr.io/<owner>/myapp-data
    tag: v20260822-abc1234        # NEVER `latest` — rejected at deploy
    module: myapp_data.definitions
    why: "What this installation loses if it stops running"
    env_secrets:
      - myapp-database-url        # secrets in the `dagster` namespace
```

Then:

```bash
./uis deploy dagster
```

The playbook reads the file, validates every entry, renders a values overlay and
passes it to Helm. Nothing in the product changes.

### Fields

| Field | | |
|---|---|---|
| `name` | required | the code-location name Dagster shows in its UI |
| `image` | required | repository, without the tag |
| `tag` | required | an immutable tag — **`latest` is rejected** |
| `module` | required | Python module exposing `definitions` |
| `why` | required | what this installation loses if it stops running |
| `env_secrets` | optional | secrets in the `dagster` namespace to expose to the pods |

### Why two of those are enforced rather than advised

**`latest` is rejected at deploy time.** Helm rolls the code-location pod only
when the image field *changes*. With `latest` the values are byte-identical every
deploy, Helm does nothing, and the platform silently keeps serving the previous
code — a deploy that reports success and changes nothing. Immutable tags make
that impossible rather than merely discouraged.

**`why:` is required**, the same rule Prometheus applies to scrape targets: a
tenant nobody can justify is one nobody maintains. In eighteen months someone
will find this entry and need to know whether anything still depends on it.

### Any language, not just Python

Dagster is a Python application, but a code location does **not** have to be
Python work. `dagster-pipes` lets an asset shell out to a process in any language
and stream its logs and metadata back into the asset graph.

That property is why Dagster is a *platform service* rather than one team's tool:
an application can bring TypeScript, Go or a shell script and still get
scheduling, lineage and freshness. The first UIS tenant orchestrates a TypeScript
ingest this way.

### Requirements on your image

| | |
|---|---|
| Entrypoint | `dagster api grpc --module-name <your_module>.definitions --host 0.0.0.0 --port 4000` |
| Port | `4000` |
| Dagster version | must match the platform's **minor** line (`1.13.x` today) |
| Module | must import cheaply — every run pod cold-starts by importing it, so open no database connections at module scope |

:::caution Version bumps are co-ordinated
The platform and every code location must stay on the same Dagster minor line; a
platform-only bump can break the gRPC handshake. The flow is: the application
rebuilds its image against the new line and confirms, **then** UIS bumps the
pinned chart. Neither side moves alone.
:::

## Concurrency

The platform caps simultaneous run pods at **4**, set in
`manifests/360-dagster-config.yaml`:

```yaml
concurrency:
  enabled: true
  runs:
    maxConcurrentRuns: 4
```

This is **platform policy, not application configuration** — deliberately, and it
is the one Dagster setting that *does* live in the product manifest rather than
the extend file. Run pods all talk to the same shared PostgreSQL that other
services use, so the ceiling protects every tenant and must be changeable without
any of them rebuilding an image. Do not throttle in application code to
compensate; raise this instead, on evidence from real materialisations.

## The metadata database

Dagster keeps run history, the event log, schedule state and the asset catalogue
in its **own** `dagster` database on the shared PostgreSQL — never inside a
tenant's database. Platform state has a different lifecycle, backup expectation
and owner than the data being orchestrated.

:::info Undeploy preserves your history
`./uis undeploy dagster` removes the Helm release but **keeps the `dagster`
database**. A redeploy resumes with run history, asset records and schedules
intact. Discarding it is a separate, explicit act:

```bash
kubectl exec -n default postgresql-0 -- \
  env PGPASSWORD=<pw> psql -U postgres -c "DROP DATABASE dagster"
```
:::

## Security and exposure

The Dagster UI is an **operator tool** and is internal-only on every
installation. Dagster OSS has no built-in authentication, so access control is
network-level: `dagster.localhost` on Rancher Desktop, the tailnet on a Proxmox
installation. There is no public-facing case for it.

Authentik OIDC via a Traefik `forwardAuth` middleware is the documented next step
and is deliberately not day-1 work.

**Telemetry is disabled.** The upstream chart defaults to sending usage data to
Dagster Labs; UIS turns it off. Nothing leaves an installation uninvited.

## Verifying

```bash
./uis verify dagster
```

Three assertions, and the third is the reason the others are not enough:

| | |
|---|---|
| **A** | the webserver answers a GraphQL query — not merely that its pod is Running |
| **B** | Dagster migrated its schema into the `dagster` database |
| **C** | the **daemon's heartbeat is fresh** |

C matters most. A daemon pod can be `1/1 Running` with a stalled heartbeat, and
then **no schedule fires** while `./uis status` stays green and the UI keeps
serving pages. Nothing else in the platform detects that. If you are relying on
Dagster to keep data fresh, this is the check that tells you it still is.

## Troubleshooting

```bash
kubectl get pods -n dagster                       # webserver + daemon
kubectl logs -n dagster deploy/dagster-daemon     # schedules and the run queue
kubectl exec -n dagster deploy/dagster-daemon -- dagster-daemon liveness-check
kubectl get deploy -n dagster \
  -l component=user-deployments                   # registered code locations
```

**A code location will not load.** Check the gRPC entrypoint, that the port is
4000, and that the image's Dagster version matches the platform's minor line — a
mismatch shows as a handshake failure rather than an obvious version error.

**Schedules are not firing.** Check the daemon first — `liveness-check` above.
Pod status will not tell you.

**A first deploy seems to hang.** A polyglot code-location image can be 1.5–2 GiB;
a cold pull takes minutes before anything else happens.
