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
      - myapp-database-url        # a secret in the `dagster` namespace;
                                  # its keys become env vars — see below
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
| `env_secrets` | optional | secrets **in the `dagster` namespace** to expose to the pods. ⚠️ Every key becomes an environment variable, and the two ways to create the secret produce **different** key names — see below |
| `env_from_services` | optional | plain environment variables set to the **in-cluster address of a UIS service** — see below |

### Addressing another UIS service from a code location

A code-location pod that has to call a UIS service — a REST API, a database —
needs an address that is valid **inside the cluster**. An application's own
published URL is not it:

```yaml
exports:
  api-url: "http://api-myapp.localhost"     # a browser on the HOST
```

`.localhost` is loopback by definition ([RFC 6761]), so delivering that value
into a pod points the pod at **itself**. The failure looks like a broken
cluster: the name resolves, the connection is refused, and the ingress is
blameless.

[RFC 6761]: https://www.rfc-editor.org/rfc/rfc6761

Name the **service** instead, and UIS composes the address:

```yaml
code_location:
  name: myapp-data
  env_from_services:
    MYAPP_API_URL: postgrest
```

The pod receives `MYAPP_API_URL=http://myapp-postgrest.postgrest.svc.cluster.local:3000`.

:::warning Do not write that address yourself
The namespace, the service name and the port belong to UIS and **change between
releases** — `gravitee` has already moved from namespace `default` to
`gravitee`. An application holding the literal address breaks silently the day
UIS moves it, in a different repository, with no signal at the source.

Naming the service keeps the moving part on the side that moves it: UIS updates
its own service data in the same release and your definition needs no change.
:::

A service UIS publishes no in-cluster address for is **refused**, not guessed at.

:::info Moving an existing variable is a replacement, not an addition
Setting the same variable in **both** `env_from_exports` and
`env_from_services` is refused, so delete the old entry in the same change that
adds the new one.

The refusal looks the wrong way round — an older UIS ignores
`env_from_services`, delivers the host-facing export, and installs. It is
deliberate. Replacing means an older UIS sets **nothing**, and the check reports
*cannot check* naming the variable: one line, and true. Adding both means an
older UIS delivers the **loopback** value, which resolves, reaches the pod
itself, and reads as a cluster problem.

Nothing is installed when the refusal fires — it runs before the plan.
:::


### Creating a secret for `env_secrets`

`env_secrets` names secrets that must already exist **in the `dagster`
namespace**. There are **two ways to create one, and they produce different
environment-variable names.** Pick one deliberately — the difference is invisible
until a run pod fails to connect.

Every key in the secret becomes an environment variable in the code-location pod
**and in every run pod it spawns**. So the key you choose *is* the variable your
code reads.

#### Path 1 — `uis configure` (also creates the database)

If the secret is a PostgreSQL connection string, UIS will create the database,
its owning role, *and* the secret in one command:

```bash
./uis configure postgresql --app myapp \
  --namespace dagster --secret-name-prefix myapp-database \
  --json
```

⚠️ Two things about the result that you cannot guess from the flags:

- the Secret is named **`myapp-database-db`** — `--secret-name-prefix` is a
  prefix, and `-db` is appended
- its key is always **`DATABASE_URL`**. The name is hardcoded; there is no flag
  for it

So the declaration must read:

```yaml
    env_secrets:
      - myapp-database-db       # supplies DATABASE_URL
```

and your code reads `DATABASE_URL`.

#### Path 2 — `kubectl`, when you want the name you choose

Use this when the secret is not a database URL, or when your code already reads a
prefixed variable:

```bash
kubectl create secret generic myapp-database-url \
  --namespace dagster \
  --from-literal=MYAPP_DATABASE_URL='postgresql://user:pass@postgresql.default:5432/myapp'
```

```yaml
    env_secrets:
      - myapp-database-url      # supplies MYAPP_DATABASE_URL
```

Here the secret name and the key are both yours, and your code reads
`MYAPP_DATABASE_URL`.

#### Which to use

| | Path 1 (`uis configure`) | Path 2 (`kubectl`) |
|---|---|---|
| Creates the database and role | ✅ yes | ❌ no — do it first |
| Applies your migrations | ✅ `--init-file -`, with rollback | ❌ no |
| Secret name | `<prefix>-db`, derived | yours |
| Variable your code reads | `DATABASE_URL`, fixed | yours |
| Password handling | generated, not stored by UIS | you supply it |

Path 1 is the shorter install and the one to prefer for a Postgres-backed tenant.
Path 2 is the escape hatch. **What is not supported is assuming Path 1 and
reading a prefixed variable** — that pod starts clean, reports `LOADED`, and then
every run fails at connect time.

If the secret is missing entirely the pods will not start, and
`./uis verify dagster` reports the location as unreachable.

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

## Installing does not start anything

`uis template install` deploys the code location and loads nothing. The jobs it
lists at the end are a **one-time load**, and the install summary now says so —
carrying the application's own `operational.automation` sentence, the assets
that have no schedule at all, and how to check the real state:

```
./uis dagster automation
```

:::danger A green install can sit there while the data ages
The install summary answers "why is my API empty" and hands over an ordered job
list. An operator runs them, watches the data land, and reasonably concludes the
install is finished.

`./uis verify dagster` **passes in both states** — it proves the daemon *can*
fire schedules, not that any schedule is switched **on**. So nothing in the
install, and nothing in verify, distinguishes a running installation from a
stopped one.

An acceptance host was found holding a correct, verified, digest-pinned install
whose register had stopped tracking reality **12.8 hours earlier**, with 3,075
unapplied upstream changes. Every check was green.
:::

:::warning "Enable the schedules" is not always the right instruction
An asset driven by an automation condition has **no schedule to switch on** — it
runs from a sensor, and `default_automation_condition_sensor` ships stopped too.
Someone told to enable the schedules would enable every schedule and still not
be running it.

That is why the installer prints the `unscheduled` list separately, and why it
says *schedules **and** sensors*.
:::

:::note UIS reports this state; it does not change it
`uis dagster automation` reads whether each schedule and sensor is RUNNING or
STOPPED. Switching them on is done in the Dagster UI. The start/stop verbs are
deliberately unimplemented: the GraphQL mutation signatures are version
sensitive, and guessing them would produce a command that silently does nothing.
:::

## Pinning the code image

A code location declares `image:` and `tag:`. The `tag` must not be `latest` —
that rule is about Helm rolling the pod when the image string changes.

:::danger An immutable-looking tag is not an immutable tag
`v20260911-f4bf175` satisfies the `latest` rule completely and **can still be
re-pushed**. Nothing at a registry prevents it.

UIS pulls an application's **install definition** at a digest and checks it
against the pin the catalogue records. Until 1.6.62 the **code image** — the
thing that actually executes — had no digest field at all, so an application
could not pin it even if it wanted to. A re-push changed what ran while every
digest UIS printed stayed identical.
:::

Declare the digest to pin it:

```yaml
code_locations:
  - name: atlas-data
    image: ghcr.io/terchris/atlas-data
    tag: v20260911-f4bf175
    digest: sha256:d7a371f7...     # optional
    module: atlas_data.definitions
    why: "..."
```

`./uis deploy dagster` resolves the tag at the registry and **refuses** if it no
longer resolves to the declared digest.

**The field is optional on purpose** — an application that cannot publish
digests must still be installable. What is *not* optional is knowing the value:

| command | answers |
|---|---|
| `./uis deploy dagster` | what the tag resolves to **now**, for every code location, declared or not |
| `./uis verify dagster` (check E) | what each location is **actually running**, read from `imageID`, **compared against the declared digest** |

An application publishes the digest in its own install definition, and
`uis template install` writes it into the overlay:

```yaml
# template-info.yaml, inside the code-location block
digest: sha256:86c5aed1...
```

:::warning A reported digest is not a verified one
Check E **fails** when a running digest does not match the declared one, and
says how many locations were actually compared. A location that declares no
digest still has its running digest reported — but nothing was checked, and E
says so rather than letting a green result read as a verified pin.
:::

:::note Why `imageID` and not `image`
`image` is what was asked for — `repo:tag`, the same string already in the values
file. `imageID` is what the kubelet actually pulled and started, digest and all.
Reporting `image` would look like a verification and assert nothing.
:::

:::warning "Could not look" is not "does not match"
A private registry answering 401 means the digest could not be resolved. The
deploy says **NOTHING WAS COMPARED** and continues — the declaration is
unverified, not verified. It never reports that as a mismatch.
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

The platform allows **1800 seconds**, up from the chart default of 300:

```yaml
dagsterDaemon:
  runMonitoring:
    enabled: true
    startTimeoutSeconds: 1800
```

It was 900 until a measured launch wrote **~685 planning events in ~885 seconds**
— fifteen seconds of margin. The same launch took 364 s once and 885 s the next
time, so the 2.4x spread is **concurrent load, not plan size**.

:::warning This is margin, not a cure
If you hit `START_TIMEOUT`, the question to ask is **how many asset checks the
run creates** — not how large the plan is. Plan size is not the variable.

The cost is writing check events one at a time at run creation, so N smaller
jobs each pay 1/N of it. That makes splitting a job a real lever, but only when
the check count is what is driving it — check the count before decomposing
anything.
:::

:::danger This value ships in the image and does NOT reach a running cluster
`startTimeoutSeconds` lives in the deployed Dagster release, not in the
provision-host image. **Upgrading UIS does not apply it.** The running value is
whatever the last Dagster deploy wrote:

```bash
kubectl get configmap dagster-instance -n dagster \
  -o jsonpath='{.data.dagster\.yaml}' | grep start_timeout_seconds
```

To apply the shipped value, redeploy Dagster:

```bash
uis deploy dagster
```

That runs `helm upgrade` with these values. The chart annotates the daemon
Deployment with a checksum of the instance ConfigMap, so the daemon rolls and
re-reads automatically — no manual restart. Re-read the ConfigMap afterwards to
confirm; a command exiting 0 is not the same as a value having changed.
:::

## What an install actually costs

Measured on a real acceptance install, so these are observations rather than
estimates. The host was **3 vCPU, Sandy Bridge era** — deliberately modest, and
slower than a developer laptop.

| step | time |
|---|---|
| `uis template install atlas` | **264 s** |
| `annual_sources_refresh` | ~11 min |
| `klass_refresh` | 67 s |
| `seed_sources_refresh` | 50 s |
| `brreg_bootstrap` (first load) | **492 s** |
| `transform_and_publish` | ~19 min |
| whole chain, disk used | ~6 GiB |

:::warning A re-run can cost more than the first load
`brreg_bootstrap` took **867 s against a populated table versus 419 s empty** —
**2.1×** — because upserting 1.17M rows into an existing table is more work than
filling an empty one.

The intuition runs the other way: a re-run feels like it should be cheaper
because "the data is already there". Size a maintenance window on the re-run
number, not the first-load number.
:::

:::note These are one host's numbers
The point of recording them is the **shape** — which steps dominate, and that a
re-run is more expensive than a first load — not the absolute values. A timeout
tuned on a fast developer machine has less headroom on the host that actually
runs the install.
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

## 🔴 A run executed the previous image and reported success

This has two different causes with two different remedies, and **from outside they look identical**: same command, same shell, a build you did not ship. Tell them apart before fixing either.

### What selects the image for a run pod

UIS configures `K8sRunLauncher` with **no `job_image` key**, so the image is not pinned by the launcher. It comes from the code location's origin — and that origin is **snapshotted from the webserver's cached workspace at the moment the run is created**, not read from the live Deployment.

🔵 So the authority is *the webserver's handle*, not the code-location pod. A pod can be healthy, on the right digest, with `DAGSTER_CURRENT_IMAGE` agreeing, while runs still execute the previous build.

### Cause 1: a stale handle — the webserver predates the code location

The usual one. The webserver and daemon are long-lived; a code-location bump rolls only the code-location Deployment, so the two servers keep serving the handle they cached.

```bash
./uis dagster verify        # summary line F: FRESH | STALE | UNREADABLE
```

⚠️ **F is advisory — the command exits 0 under STALE**, because everything else genuinely passes and it is a warning about the *next* run. Gate a script on it with `./uis dagster verify --strict`.

```bash
kubectl -n dagster rollout restart deploy/dagster-dagster-webserver
kubectl -n dagster rollout restart deploy/dagster-daemon
```

🔴 **`./uis deploy dagster` does not fix this.** With Helm values unchanged it rolls nothing and reports success. Restarting the two pods is what picks up the new handle.

### Cause 2: two code locations claim the same job name

Distinguishable by one property: **cause 1 is consistent, cause 2 is not.** A stale handle gives the old image to *every* run until you restart. If one run gets the new image and a later one gets the old, the handle is not the explanation.

```bash
kubectl get pods -n dagster -l component=user-deployments \
  -o custom-columns=NAME:.metadata.name,IMAGE:.spec.containers[0].image
```

More than one location defining the same job is usually one left behind by an earlier install. **Each carries its own image**, so which one you get decides which code runs.

`uis dagster run` **refuses** this rather than picking, because Dagster promises no ordering and an arbitrary pick executes code you did not choose while reporting success:

```bash
./uis dagster run <job> --location <name>
```

:::warning Which question each command answers
`uis deploy dagster` asks *did the Helm release apply*. `uis dagster verify` asks *are the locations loaded, and is the handle fresh*. **Neither asks "will the next run execute the image I just installed"**, and a run that succeeded is not evidence either — it may have executed the old one and passed.

The honest check is the run's own image, after the fact.
:::

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
