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
| `env_secrets` | optional | secrets **in the `dagster` namespace** to expose to the pods — see below |

### Creating a secret for `env_secrets`

`env_secrets` names secrets that must already exist **in the `dagster`
namespace**. UIS does not create them for you — your application's installer
does, the same way it writes the declaration:

```bash
kubectl create secret generic myapp-database-url \
  --namespace dagster \
  --from-literal=MYAPP_DATABASE_URL='postgresql://user:pass@postgresql.default:5432/myapp'
```

Every key in the secret becomes an environment variable in the code-location pod
**and in every run pod it spawns**. If the secret is missing the pods will not
start, and `./uis verify dagster` reports the location as unreachable.

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
| **Run storage** | must include **`dagster-postgres`** (`0.29.x` for the `1.13.x` line) |

:::danger `dagster-postgres` is required, and its absence is invisible until a run
Run pods are launched from **your** image, and this platform stores runs in
Postgres — so your environment must be able to import
`dagster_postgres.run_storage` before a single step executes.

Without it, everything looks fine: the location loads, reports `LOADED`, serves
its assets and schedules, and the pod sits at 0 restarts. Then the first run
reaches `LaunchRunSuccess`, starts a pod, and **dies in about 5 seconds with
`stepsSucceeded: 0`** and:

```
CheckError: Failure condition: Couldn't import module dagster_postgres.run_storage
when attempting to load the configurable class
dagster_postgres.run_storage.PostgresRunStorage
```

This row was missing from this table until 2026-08-23. The first real tenant met
every requirement that *was* documented and still could not execute anything —
the requirement was real, undocumented, and unchecked. `./uis verify dagster` now
pre-flights it (check D5) so it surfaces at verify time rather than as a mystery
run failure.
:::

:::caution Version bumps are co-ordinated
The platform and every code location must stay on the same Dagster minor line; a
platform-only bump can break the gRPC handshake. The flow is: the application
rebuilds its image against the new line and confirms, **then** UIS bumps the
pinned chart. Neither side moves alone.
:::

## Run start timeout

A run's **entire execution plan is constructed and persisted over gRPC before its
pod is created**. A job with a very large plan can therefore exhaust the start
timeout while everything is healthy, and the failure names something that was
never involved:

```
RunFailureReason.START_TIMEOUT
```

That reads like a scheduling problem or an image pull, and it is neither. The
first real tenant hit it with a job planning **711 events** (645 of them asset
checks): the code location was healthy, port 4000 open, and smaller jobs on the
same location ran fine.

The platform allows **900 seconds**, up from the chart default of 300:

```yaml
dagsterDaemon:
  runMonitoring:
    enabled: true
    startTimeoutSeconds: 900
```

:::warning This is margin, not a cure
If you hit `START_TIMEOUT`, the question to ask is **how large is the plan**, not
whether the timeout can go higher. The durable fix is to split a monolithic job
so no single plan is that big; raising the ceiling further just hides the next
instance for longer.

Count the events in the run's plan before concluding the platform is slow.
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
any of them rebuilding an image. Do not duplicate this cap in application code;
raise it here instead, on evidence from real materialisations.

### It bounds runs, not steps — and the difference matters

`maxConcurrentRuns` is nested under `runs:` for a reason. **It bounds how many runs
execute at once. It does not bound how many steps run inside one of them.**

A fan-out job — one job materialising dozens of assets — is **a single run**. Inside
that run pod, Dagster's multiprocess executor takes `max_concurrent` from the pod's
CPU count by default, and this manifest sets no executor bound at all. So on a
fan-out job the platform cap **never engages**: one run cannot exceed a ceiling of
four runs.

Measured on the reference installation: a weekly job fired **37 assets** in **one**
run, with a peak of **4 concurrent steps**. That 4 came from the application's own
bound, not from this manifest. The platform cap was never reached by that job and
could not have been.

:::warning A step-level bound is not a duplicate of this cap — keep it
If your job fans out, bound your own step concurrency. It is the only thing standing
between a wide job and as many concurrent database writers as the run pod has CPUs,
against a PostgreSQL that other services share — and, if the job fetches from
external APIs, as many simultaneous callers to those.

The advice above is *"do not re-implement the run cap in application code"*. It is
**not** "do not bound concurrency in application code". Deleting a step-level bound
because this section caps runs at 4 removes a control the platform does not provide,
and the failure is quiet: unbounded writers, not an error.

Read your bound from an environment variable with a default — `os.getenv` with a
fallback, never a required variable — so the platform can retune it without you
rebuilding an image. That honours the same principle this cap is built on.
:::

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

Four checks, and C is the reason the first two are not enough:

| | |
|---|---|
| **A** | the webserver answers a GraphQL query — not merely that its pod is Running |
| **B** | Dagster migrated its schema into the `dagster` database |
| **C** | the **daemon's heartbeat is fresh** |
| **D** | every declared code location **loaded** — asked of Dagster, not of Kubernetes |

C matters most. A daemon pod can be `1/1 Running` with a stalled heartbeat, and
then **no schedule fires** while `./uis status` stays green and the UI keeps
serving pages. Nothing else in the platform detects that. If you are relying on
Dagster to keep data fresh, this is the check that tells you it still is.

D asks **Dagster's workspace**, not Kubernetes. A code location whose image
cannot be pulled still has a running Deployment — counting pods would call that
"registered" while none of its assets, jobs or schedules exist. An unreachable
location is reported as a **failure**, not a count.

## Troubleshooting

```bash
kubectl get pods -n dagster                       # webserver + daemon
kubectl logs -n dagster deploy/dagster-daemon     # schedules and the run queue
kubectl exec -n dagster deploy/dagster-daemon -- dagster-daemon liveness-check
kubectl get deploy -n dagster \
  -l component=user-deployments                   # code-location PODS (not proof they loaded)
```

**A code location will not load.** Check the gRPC entrypoint, that the port is
4000, and that the image's Dagster version matches the platform's minor line — a
mismatch shows as a handshake failure rather than an obvious version error.

**Schedules are not firing.** Check the daemon first — `liveness-check` above.
Pod status will not tell you.

**A first deploy seems to hang.** A polyglot code-location image can be 1.5–2 GiB;
a cold pull takes minutes before anything else happens.

**A deploy hangs for 15 minutes and then fails.** Almost always a tenant image
tag that does not exist. Helm waits out its full `--timeout 900s` before giving
up. The deploy now pre-flights each declared image against the registry and warns
in seconds — check the top of the output for a `⚠️ registry returned 404` line
before waiting.
