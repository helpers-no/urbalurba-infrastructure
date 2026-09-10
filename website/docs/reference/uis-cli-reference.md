---
title: UIS CLI Reference
sidebar_label: CLI Reference
---

# UIS CLI Reference

The `./uis` command manages the UIS provision-host container and all services within it. Commands are organized into host-level (managing the container) and service-level (managing Kubernetes services inside the container).

## Container Management

These commands run on the host machine and manage the UIS container.

| Command | Description |
|---------|-------------|
| `./uis start` | Start the UIS provision-host container |
| `./uis stop` | Stop the container |
| `./uis restart` | Restart the container |
| `./uis container` | Show container status |
| `./uis shell` | Open interactive bash shell in the container |
| `./uis exec <command>` | Execute a command inside the container |
| `./uis logs [--tail N]` | Show container logs (default: last 50 lines) |
| `./uis build` | Build the container image locally as `uis-provision-host:local` |

## Platform Management

UIS targets multiple Kubernetes platforms (Rancher Desktop, Azure AKS, …). The `uis platform` subcommands surface them all under a single command interface. See [Platforms overview](../platforms/index.md) for the full mechanic.

| Command | Description |
|---------|-------------|
| `./uis platform list [--offline\|--deep]` | List all platforms and their state. `--offline` skips reachability probe; `--deep` adds per-platform extras (e.g. cluster version, cost). |
| `./uis platform use [<name>] [--offline]` | Switch the active platform — kubectl context + `cluster-config.sh` flip together. No arg → interactive picker over reachable platforms. `--offline` allows switching to an unreachable platform (e.g. to clean up stale state). |
| `./uis platform init <provider>` | Interactive setup wizard for a cloud platform. Writes `.uis.secrets/cloud-accounts/<provider>-default.env`. |
| `./uis platform up <provider>` | Provision the cluster end-to-end. Chains bootstrap + tofu apply + post-apply configuration. Auto-flips active platform to the new cluster on success. |
| `./uis platform status <provider>` | Show cluster state, external IP, and rough cost estimate. Does not target the active platform — reports on the named one. |
| `./uis platform down <provider>` | Tear down the cluster. Requires typing the cluster name to confirm (irreversible). Auto-resets active platform back to `rancher-desktop` on success. |

### `platform list` — canonical output

```
$ ./uis platform list
Active: rancher-desktop

PLATFORM          STATUS
rancher-desktop   ✓ running  (active)    local k3s
azure-aks         · configured, not running  (run './uis platform up azure-aks' to start it)
```

Four possible state values per row: `✓ running`, `· configured, not running`, `· not initialized`, `✗ unreachable`. See [Platforms overview](../platforms/index.md) for what each means.

### `platform use` — canonical output

```
$ ./uis platform use rancher-desktop
✓ Switched: azure-aks → rancher-desktop
```

```
$ ./uis platform use      # no arg → interactive picker
     PLATFORM          STATUS
[1] rancher-desktop   ✓ running  (currently active)    local k3s
    azure-aks         · configured, not running  (run './uis platform up azure-aks' to start it)

Pick a platform [1-1]:
```

Only `running` platforms get selectable numbers. Switching to a `not initialized` or `unreachable` platform doesn't have a meaningful outcome.

### Banner on every cluster-touching command

`./uis deploy`, `./uis undeploy`, `./uis list`, `./uis status`, `./uis configure`, `./uis expose`, `./uis stack install`, and `./uis test all` all print a one-line banner identifying the active platform before running:

```
$ ./uis deploy nginx
ℹ  Platform: azure-aks (reachable)
(deploy output follows…)
```

If no platform is active or the active platform is unreachable, the banner aborts the command with a recovery hint. See [Platforms overview](../platforms/index.md#banner-on-every-cluster-touching-command) for all four banner cases.

## Network Management

UIS supports two networking providers — Cloudflare (production-grade tunnels with WAF + your own domain) and Tailscale (per-service Funnel for dev sharing on any network). The `uis network` subcommands manage both under a single command surface. See [Networking](../networking/index.md) for the comparison + walkthrough.

| Command | Description |
|---------|-------------|
| `./uis network list` | List both providers and their state. |
| `./uis network init <provider>` | Interactive setup wizard. `<provider>` is `cloudflare` or `tailscale`. |
| `./uis network up <provider> [flags]` | Deploy the provider into the cluster. Tailscale supports `--with-cluster-funnel` for an opt-in catch-all device. |
| `./uis network down <provider>` | Tear down the provider's cluster footprint. |
| `./uis network status <provider>` | Show provider state, tunnel/route state, pod health. |
| `./uis network verify <provider>` | Run the provider's diagnostics. |
| `./uis network expose tailscale <service> [--yes]` | Expose a service via a per-service Tailscale Funnel device. Namespace auto-detected. Tailscale-specific — Cloudflare uses cluster-wide HostRegexp routing instead. |
| `./uis network unexpose tailscale <service>` | Undo per-service Funnel exposure. |

## Service Management

### Discovery

| Command | Description |
|---------|-------------|
| `./uis list` | List all services with deployment status |
| `./uis list --category <id>` | Filter by category (e.g., `DATABASES`, `OBSERVABILITY`) |
| `./uis list --all` | Show all services including disabled |
| `./uis status` | Show deployed services health and cluster context |
| `./uis categories` | List all service categories |

### Deploy and Undeploy

| Command | Description |
|---------|-------------|
| `./uis deploy` | Deploy all enabled/autostart services |
| `./uis deploy <service-id>` | Deploy a specific service (auto-enables it) |
| `./uis undeploy <service-id>` | Remove a service from the cluster |

### Autostart Configuration

Services can be marked for automatic deployment.

:::warning "Autostart" does not mean "starts at boot"
Nothing in UIS runs when the machine boots. The enabled list only decides what
`./uis deploy` deploys **when you run it with no arguments** — it is a default
argument list, not a startup mechanism.

What actually happens after a host restart:

- **Deployed services come back on their own.** Deployments, Services,
  IngressRoutes, Secrets and database roles are cluster state; once the cluster
  is running again the kubelet restarts the pods. **Nothing needs redeploying,
  and re-running `./uis deploy` is not the fix.**
- **The cluster itself is not started by UIS.** Rancher Desktop is installed at
  OS level, so whether it comes up with the machine is a host setting outside
  UIS's control.

So if services are unreachable after a reboot, check whether the **cluster** is
running before redeploying anything.
:::

| Command | Description |
|---------|-------------|
| `./uis enable <service-id>` | Add service to autostart (deploys on next `./uis deploy`) |
| `./uis disable <service-id>` | Remove from autostart (does not undeploy) |
| `./uis list-enabled` | Show all services in autostart configuration |
| `./uis sync` | Auto-enable all currently deployed services |

### Verification

| Command | Description |
|---------|-------------|
| `./uis verify <service-id>` | Run service-specific verification checks |

## Stack Management

Stacks are pre-configured groups of related services deployed together.

| Command | Description |
|---------|-------------|
| `./uis stacks` | List all available stacks |
| `./uis stack info <stack-id>` | Show stack details (components, dependencies) |
| `./uis stack install <stack-id>` | Install all services in a stack in order |
| `./uis stack install <stack-id> --skip-optional` | Skip optional services |
| `./uis stack remove <stack-id>` | Remove all services in a stack |

Available stacks: `observability`, `ai-local`, `analytics`

## Template Management

A **template** installs an application that spans several services — a database
with migrations, per-app instances, exposures — under one name and one
`app_name`. It is the `uis` half of
[Rules for Deploying Applications](../contributors/rules/application-deployment.md):
templates provision, ArgoCD deploys workloads.

| Command | Description |
|---------|-------------|
| `./uis template list` | List available UIS templates from the registry |
| `./uis template info <id>` | Show one template's details |
| `./uis template install <id> [--dry-run] [--param k=v]...` | Deploy and configure every service the template declares |
| `./uis template remove <id> [--app <name>] [--purge] [--yes]` | Remove an installed application. **Data is kept unless `--purge`.** `--app` picks one tenant when a template has several |

### `--dry-run`

Prints every `deploy`/`configure` the install would run, in order, with params
resolved, and runs nothing. ⚠️ It is a dry run of the **install**, not of the
**fetch** — the definition artifact is pulled, because that is how the plan is
known. Nothing else is written.

### Several tenants of one template

`--param app_name=` installs a second, independent tenant — a live one and a
test one, say. The record holds **one entry per tenant, keyed on `app_name`**,
so they do not collide.

🔴 **Before 1.6.35 the record was keyed on the template id**, so a second
install silently replaced the first's record: the first tenant stayed deployed,
healthy and serving traffic, and could no longer be removed by the tool that
installed it.

Consequences worth knowing:

- `remove <id>` is **ambiguous** once a template has two tenants, and refuses,
  listing the `--app` values it knows: `./uis template remove atlas --app atlas-t`
- `requires: <id>` is ambiguous the same way and refuses for the same reason —
  two tenants export different URLs and nothing can say which you meant
- a record with **no** `app_name` (written before 1.6.29) cannot be keyed, so
  recording one is refused rather than allowed to collide

### `--param app_name=` and what `remove` remembers

The install records the **effective** `app_name` in `.uis.extend/applications.yaml`,
and `remove` derives every per-app name from that — never from the application
id. They are the same string only when `--param app_name=` was not used.

🔴 **A record written before 1.6.29 has no `app_name`.** `remove` falls back to
the id, says so loudly, and **refuses `--yes`**: the plan cannot be verified
against what was installed, and the failure mode is undeploying a different
tenant's instance. Read the plan and confirm interactively, or remove by hand.

⚠️ **`app_name` becomes a SQL identifier and a Kubernetes name.** Letters,
digits, underscore and hyphen only; anything else is refused before any SQL
runs. A hyphen is fine — the database keeps it, the Postgres role converts it to
an underscore — so `--param app_name=my-app` yields database `my-app` and role
`my_app`.

### What `remove` does and does not do

It removes what the install **added**, not what the application **produced**:

| removed | kept |
|---|---|
| the code-location entries, then dagster is redeployed | databases, roles and secrets |
| per-app instances of multi-instance services | single-instance shared services |
| the application record | |

⚠️ **Single-instance services are never undeployed.** `postgresql` is shared; an
application does not own it, and removing an application must not take the
platform's database with it.

`--purge` additionally drops the per-app Postgres roles and secrets. An
application's database is the one thing reinstalling cannot reconstruct, which is
why it is opt-in — the same line `undeploy` and `configure --purge` already draw.

**Removal refuses while another installed application `requires` it**, naming the
dependant.

### The declaration

A template ships a `template-info.yaml`:

```yaml
install_type: stack
params:
  app_name: myapp            # substituted anywhere as {{ params.app_name }}

provides:
  services:
    - service: postgresql
      config:
        database: "{{ params.app_name }}"
        init: migrations/                    # a file OR a directory
        namespace: dagster                   # where to write the secret
        secret_name_prefix: "{{ params.app_name }}-database"
    - service: postgrest
      config:
        schemas: api_v1
        url_prefix: api-myapp
  stacks:
    - observability                          # expanded to its services, deploy-only
```

### `config:` keys

Every key maps to a `uis configure` flag. **An unrecognised key is rejected**, so
a typo such as `url-prefix` fails the install rather than being silently ignored.

| Key | Passed as | Notes |
|---|---|---|
| `database` | `--database` | Declared once, by whichever service owns it; **every other configurable service in the same install is passed the same value** rather than deriving its own |
| `init` | `--init-file -` | a file, or a directory — see below |
| `schemas` | `--schemas` | PostgREST |
| `url_prefix` | `--url-prefix` | PostgREST |
| `namespace` | `--namespace` | ⚠️ **requires `secret_name_prefix`** |
| `secret_name_prefix` | `--secret-name-prefix` | ⚠️ **requires `namespace`** |
| `code_location` | *(not a flag)* | A **mapping**, not a scalar — see below. Dagster only |

⚠️ The resulting Secret is named **`<secret_name_prefix>-db`** and its key is
always **`DATABASE_URL`** — see
[Dagster's tenant contract](../services/analytics/dagster.md) for why that
matters when another service consumes it.

### `code_location:` — contributing to Dagster

A `provides` entry for `dagster` may carry a `code_location` mapping. The entry
is written into `.uis.extend/dagster-code-locations.yaml` and Dagster is
redeployed, so an application that orchestrates with Dagster installs in **one**
step:

```yaml
provides:
  services:
    - service: dagster
      config:
        code_location:
          name: "{{ params.app_name }}-data"
          image: ghcr.io/terchris/atlas-data
          tag: v20260909-abc1234
          module: atlas_data.definitions
          why: "the ETL that fills api_v1"
          env_secrets: "{{ params.app_name }}-database-db"
```

| Field | Required | Notes |
|---|---|---|
| `name` | yes | The code-location name. `{{ params.* }}` is substituted **before** it is recorded |
| `image` | yes | |
| `tag` | yes | ⚠️ Must be immutable — the same rule the Dagster validator applies |
| `module` | yes | The Python module holding `Definitions` |
| `why` | no | Free text, kept in the file for whoever reads it next |
| `env_secrets` | no | Extra Secrets whose keys become environment variables. **A scalar or a list; both are accepted.** See below — you usually do not need it |

Re-installing at the same pin rewrites the same entry and changes nothing —
Helm rolls only when the image field changes. A new pin rolls the tag.

🔴 **UIS wires the Secret it created for you — do not restate it.** If the same
install ran `configure postgresql --namespace <ns> --secret-name-prefix <p>`,
the Secret `<p>-db` is added to the code location's `env_secrets`
automatically. Naming it again in the definition is harmless (it is de-duped)
but wrong in principle: the name is UIS's own construction, so a definition
that repeats it is a second place that must agree — and one that hard-codes it
breaks under `--param app_name`.

Use `env_secrets` only for Secrets **this install did not create**.

⚠️ **Without that wiring, a clean install comes up unable to reach its own
database** — `EXIT=0`, schema present, API answering, and the pipeline dead on
the first run. It took a machine that had never seen the application to expose
it, because leftover state supplied the Secret on every cluster that had one.

⚠️ **This is a code-location writer, not a generic "contribute to another
service's extend file" mechanism.** Two other files would qualify
(`prometheus-targets.yaml`, `monitors.yaml`) and the generic form was declined:
one consumer does not tell you the shape of three.

### `operational:` — what installing this will actually do

An optional top-level block in the **artifact**, rendered by
`uis template info`. UIS reads nothing from it and validates nothing in it:
the application owns the content, the platform only displays it.

It answers the questions an operator has *before* installing, and which
`provides:` cannot:

```yaml
operational:
  automation: "Ships stopped. No data is fetched until an operator enables the schedules."
  timezone: Europe/Oslo
  install:
    deploys: [postgresql, postgrest, dagster]
    takes: a few minutes
    note: "the API is live and serves zero endpoints until the first pipeline run"
  first_data:
    why: "enabling the schedules does not backfill"
    how: "launch these jobs, in this order"
    jobs: [annual_sources_refresh, klass_refresh, transform_and_publish]
    takes: "~11 minutes"
  cadence:
    - { cron: "0 2 * * 0", what: "~37 annual public-sector sources" }
  external_services: [SSB, FHI]
  unscheduled: [parked-source]
```

**Rendered in two places, deliberately.** `template info` prints the whole
block before an install; the **install summary prints the short form after
one** — the note and the `first_data` jobs, immediately below `Endpoints:`.

⚠️ **Both, because a user who runs `install` without `info` would otherwise
never see it** — and `template list` offers `info` and `install` as two equal
options with nothing marking the first as a prerequisite. Even a reader who did
run `info` met those job names several minutes and several hundred lines
earlier; the end of the output is the part that gets read.

🔴 **`automation` is the single most important line.** *Does installing this
start anything?* An operator deciding whether to install needs that before the
service list, and nothing else in the definition says it.

⚠️ **`first_data` exists because enabling schedules does not backfill.** A
cron is a *next fire*, not a catch-up, so a Thursday install can sit empty
until Sunday. An application whose data arrives on a schedule should say how to
load it now.

⚠️ **It lives in the artifact, not the catalogue entry**, so it is
version-locked to the code it describes — the same reasoning that keeps
`params:` and `provides:` out of the registry. `info` therefore pulls the
definition at its digest to render this; the pull is cached, so repeated calls
cost nothing, and a fetch failure degrades to the registry half rather than
failing the command.

### `requires:` and `exports:` — one application reading another

An application may export values a dependant needs, and declare what it needs:

```yaml
# in atlas
exports:
  api-url: "http://api-{{ params.app_name }}.localhost"

# in atlas-frontend
requires:
  - application: atlas
    provides: api-url
params:
  api_base: "{{ requires.atlas.api-url }}"
```

⚠️ **`requires:` refuses, it never auto-installs.** A missing dependency names
the application and the command that installs it, and stops. Installing one
application must not silently install another: the second one's exposure
decisions are a person's to make.

The install records what it installed in `.uis.extend/applications.yaml` — the
id, artifact, tag, **pin (digest)**, the services and code locations it created,
its `requires`, and its resolved `exports`. That record is what makes `requires`
a refusal rather than a guess: without it, "is atlas installed?" could only be
answered by probing the cluster for symptoms, and a probe that infers presence
eventually infers it wrongly.

⚠️ **A fixture or stack template installed with no artifact pin writes no
record**, and says so. A dependant's `requires:` will not see it.

### The source, the allowlist and the pin

An application's install definition is its **own OCI artifact**, published beside
its image and pulled with `oras` on the provision host — no pod, no cluster, no
docker:

```yaml
source:
  artifact: ghcr.io/terchris/atlas-data/uis
  tag: v20260909-abc1234
  digest: sha256:<64 hex>
```

| Check | Behaviour |
|---|---|
| **allowlist** | `ghcr.io/helpers-no/*` and `ghcr.io/terchris/*` by default. Anything else is refused, naming the value and the allowlist. Extend it in `.uis.extend/template-allowlist.conf` — one glob per line |
| **pin** | The **digest** is pulled; the tag is only shown. A missing or malformed digest is refused — a tag alone is not a pin, because tags are mutable at a registry |
| **immutable tag** | `latest`, `main`, `master`, `head` and an empty tag are refused even with a valid digest |

The allowlist is a security boundary, not a convenience: the definition is fed to
`configure --init-file`, which applies SQL **as the database owner**. A merged
typo in the catalogue must not be able to point a platform at a stranger's SQL.

Private artifacts use `oras login ghcr.io` with `GITHUB_USERNAME` /
`GITHUB_ACCESS_TOKEN` from the master secrets. Public artifacts are pulled
anonymously — the platform token is never touched. When the credentials are
missing, the error names **the secret, not the URL**.

⚠️ **`oras` ships in `uis-provision-host` 1.6.16 and later.** Installing an
application on an older provision host fails with `oras: not found` on a machine
whose `./uis version` may look current — run `./uis pull`.

### `./uis pull` — and the version it may not be able to give you

`pull` fetches `ghcr.io/helpers-no/uis-provision-host:latest`, a **moving tag
published by the container build**. The update notice compares the installed
version against `version.txt` on `main` — which `main` gains the moment a
release commit merges, **minutes before the image exists**, and permanently if
that build fails.

So `pull` can succeed and leave you where you were:

```
Update available: 1.6.49 -> 1.6.50   (run: ./uis pull)
$ ./uis pull
Image updated successfully
Now running version: 1.6.49
```

🔴 **Since 1.6.51 it says so, and exits 3.** After pulling, `pull` reads back
what actually arrived and compares it with `main`. When they differ it
distinguishes three cases, because they need different actions:

| what it found | what it tells you |
|---|---|
| `<repo>:<version>` **is not in the registry** | the build is still running or it failed — nothing is wrong with your machine, and it names the Actions page |
| `<repo>:<version>` **is** in the registry but `:latest` is older | a tagging fault in the release; take it by version: `UIS_IMAGE=<repo>:<version> ./uis pull` |
| the registry **could not be reached** | *"do not know"*, stated as such — never reported as "not built yet" |

🔴 **`pull`, `stop` and `restart` refuse while a UIS command is running inside
the container** (1.6.52). All three stop it, and `template install` is minutes
long — interrupting it leaves a half-built application: a database with a
partial schema, or a code location written to `.uis.extend` that Dagster never
loaded. No UIS command repairs that. The refusal names the process it found and
says how long to wait; `UIS_FORCE=1 ./uis pull` overrides it.

⚠️ **Exit 3 means the pull worked and did not deliver the advertised version.**
A script that treats any non-zero as failure will now notice; one that only
checks for zero was previously told success. Exit 0 still means you are on the
version `main` advertises.

### The registry entry — the seam with the catalogue

The `source` block above lives in the **catalogue**, not in the artifact. The
artifact carries the definition; the registry carries the pointer to it.

🔴 **The shape first, because a list of field names is not a shape.** An earlier
version of this section gave only the table below, and a reader authored
`visibility` *inside* `source` from it — which UIS reads as null and defaults to
`public`, so it works, ships, and keeps working until the first private artifact
fails by never asking for credentials (`dev-templates`, `urb-agents#479`). Their
words for it: **"correct by accident is the failure mode neither of us can
see."** So:

```json
{
  "id": "atlas",
  "templateKind": "application",
  "visibility": "public",
  "category": "APPLICATION",
  "version": "v20260909-853c696",
  "name": "Atlas Data",
  "description": "…",
  "abstract": "…",
  "tags": ["data", "dagster"],

  "source": {
    "artifact": "ghcr.io/terchris/atlas-data/uis",
    "tag": "v20260909-853c696",
    "digest": "sha256:def7b9d2…3d3a6c54"
  }
}
```

⚠️ **`visibility` is a sibling of `source`, not a member of it.** Nesting it is
accepted silently and defaults to `public`.

These are the only fields `uis template install` reads:

| field | required | what UIS does with it |
|---|---|---|
| `templateKind` | yes | Must be `application`. Read as `.templateKind // .kind`. ⚠️ The registry already has **both** `templateKind` and `install_type` — reuse one, do not add a third discriminator |
| `source.artifact` | yes | The OCI artifact, by convention `<image>/uis`. Checked against the allowlist |
| `source.tag` | yes | Shown to a human, never pulled by |
| `source.digest` | yes | 🔴 **What is actually pulled — and it must be AUTHORED, not resolved by the catalogue build.** See below |
| `visibility` | no | `public` (default) or `private`; decides whether the pull needs `oras login`. **Top-level, beside `source`** |
| `category` | yes | Must name a category whose `context` is `uis`. An `application` entry also stays listed on its `templateKind` alone, so a miscategorised one is visible rather than silently absent |
| `version`, `name`, `description`, `abstract`, `tags` | for display | What `uis template info` prints |

🔴 **`source.digest` must be authored, not resolved at catalogue-build time.**
A build that re-resolves the tag on every run tracks the tag, so a tag
re-pointed at a different artifact is *blessed* by the next unrelated build —
and UIS cannot tell, because it reads whatever the latest published registry
says and pins no version of it. Pulling a digest gives **integrity** (you get
what the digest names); only a committed, reviewable digest gives
**provenance** (a human approved this one). `dev-templates` established this on
`urb-agents#479` against an earlier claim of mine that UIS could catch it at
install time — it cannot, and does not try.

⚠️ **The artifact must agree with the entry about its own `id`.** A definition
whose `id:` conflicts with the entry it was fetched for is refused, naming both:
installing it would record the application under a name its own definition never
claimed.

Everything else in an entry is display metadata for the website and
`uis template info`. In particular `params:` and `provides:` come from the
**artifact's** `template-info.yaml` — the single source of truth — even if the
catalogue inlines a resolved copy for the site.

A commented, valid worked example lives at
`provision-host/uis/tests/fixtures/catalogue/registry-entry.example.json`.

### Testing an application install with no catalogue at all

`REGISTRY_URL_PRIMARY` accepts a `file://` URL, so a one-entry registry on disk
is enough to install a real published artifact before the catalogue carries it:

```bash
./uis template install atlas \
  REGISTRY_URL_PRIMARY=file:///mnt/urbalurbadisk/my-registry.json
```

⚠️ Set it on the `./uis` command line — `docker exec` does not inherit the
caller's environment, and the launcher forwards these by name.

🔴 **Put the file somewhere that survives `./uis pull`.** `/mnt/urbalurbadisk/`
is inside the container, which is recreated on every pull, so a registry written
there disappears and the symptom is "the entry is not published" rather than
"the file is gone". `.uis.extend/` is mounted and survives.

✅ **Editing that file and re-running takes effect immediately.** The registry
cache is keyed by the URL, and a `file://` source is never cached — read every
time, because reading a local file is free and caching it is what makes editing
it confusing. A remote registry is still cached for an hour;
`REGISTRY_CACHE_TTL=0` forces a refetch.

⚠️ **A `file://` registry that cannot be read refuses; it does not fall back to
the catalogue.** You asked for that file, so silently resolving a different
entry from the published registry would be worse than failing.

### `init:` — a file or an ordered directory

- **a file** — applied as-is
- **a directory** — every `*.sql` in it, concatenated in `LC_ALL=C sort` order

Order is part of the contract: migrations are numbered (`001_…`, `050_…`)
because DDL is order-dependent. The count and the ordered file list are printed
before anything is applied, so a partial apply is recoverable from the log.
Non-`.sql` files are ignored, and an **empty directory fails** rather than
installing nothing.

`{{ params.* }}` is substituted into the concatenated content, so a parameter may
appear in any file.

### Where your application is, after it installs

The completion summary ends with the application's endpoints, taken from its
`exports:`:

```
Endpoints:
  api-url        http://api-atlas.localhost
```

🔴 **Do not guess this URL from `--url-prefix`.** The route matches on
**hostname** — `HostRegexp('api-atlas\..+')` — so `http://api-atlas.localhost/`
answers and `http://localhost/api-atlas/` returns a bare Traefik 404. The
prefix is the subdomain, not a path.

⚠️ Only what the definition declares in `exports:` appears here. An application
that exports nothing prints no endpoints, and there is currently no other
command that will tell you — `status`, `list` and `verify` all omit it.

### What a fresh install actually gives you

🔴 **An application whose data arrives from a pipeline serves an empty API on
day one, and that is correct.** `template install` guarantees that the schema
exists, the grants are right, and the API answers — not that there is anything
in it. If the application's own orchestrator owns the migrations and the
ingest, the first rows appear on its first run, not at install.

This is worth stating because **an empty-but-correct API is indistinguishable
from a broken install to someone seeing it for the first time**, and the
instinct is to go looking for the failure. It is also why data freshness belongs
in a monitor rather than in `uis verify`: the platform cannot know when an
application's first pipeline run is due.

An application's catalogue entry should say so in its own words —
[atlas](https://github.com/terchris/atlas) does.

### `init:` on a database that already exists

Installing onto a database that is already there — a re-install, or an
application already running on the cluster — takes a different path, and it is
worth knowing what it does:

| | |
|---|---|
| the database and its role | **kept**, never recreated |
| the password | **preserved.** It is read back from the Secret UIS wrote. `--rotate` mints a new one; nothing else does |
| `init:` | **re-applied**, and the result reports `init_applied` |
| a failing `init:` | refuses and **does not drop the database** — that data predates the command. ⚠️ It is not left untouched: statements before the failure are already committed, so the schema can be left part-applied. See [PLAN-cli-init-file-partial-apply](../ai-developer/plans/backlog/PLAN-cli-init-file-partial-apply.md) |

### A role that outlived its database

Removing an application without `--purge` drops nothing, and dropping the
database by hand afterwards leaves the per-app **role** behind. The next install
therefore meets a *missing database and an existing role* — the **create** path,
with the role already there.

| | |
|---|---|
| the role | **kept**, never dropped — it may own objects this command knows nothing about |
| its password | 🔴 **RESET** to the one this install publishes, and the command says so |
| rollback | if a later step fails, a role that **predates** the command is never dropped; one this command created is |

⚠️ **The reset invalidates any other consumer of that role** until its pods
restart — the same hazard `--rotate` carries. It is still the right trade: the
alternative is publishing a credential that is wrong for everyone.

⚠️ **Before 1.6.49 this branch was silent and produced a broken install.**
`CREATE USER` failed, the failure was discarded because a guard checked only
that the role *existed*, and the install reported `status: ok` while writing a
password that had never been set on the role. The application came up unable to
authenticate (`ops`, `urb-agents#595`).

🔴 **`--rotate` will break a running workload** until its pods restart and
re-read the Secret. Environment-variable consumers — a Dagster code location,
for instance — read the credential once at pod start.

⚠️ **This used to happen on every re-install, unasked.** The rotation existed
because "UIS does not store per-app passwords" — but it does, in the Secret it
wrote, so it now reads it back instead. A re-install that reports `EXIT=0` and
leaves the application unable to authenticate is not a trade worth making for a
credential nobody asked to change. The JSON reports `rotated` either way.

⚠️ **Re-applying `init:` is safe by contract, not by luck.** An `init:` must
satisfy *the schema after one application equals the schema after two*. That is
a stronger requirement than "each statement is idempotent" — a set of
individually-idempotent files can still converge on the wrong schema, which is
exactly what happened to the first application's migrations and was only found
by measuring pass 1 against pass 2 (`urb-agents#362`).

⚠️ **Zero-pad your numbers.** Sorting is lexicographic, so `9_`, `10_`, `100_`
apply in *reverse* — and out-of-order DDL can succeed while leaving the wrong
schema, which is the one failure this ordering contract exists to prevent. UIS
warns when numeric and lexicographic order disagree and shows what numeric order
would have been, but it applies the lexicographic order regardless: it cannot
know which you meant. `001_`, `002_`, … `010_` is immune.

### Testing a template before publishing it

`REGISTRY_URL_PRIMARY`, `REGISTRY_URL_FALLBACK` and `TEMPLATE_REPO` honour an
environment override, so a template can be exercised before it reaches the
registry:

```bash
TEMPLATE_REPO=/path/to/local/dev-templates ./uis template install my-fixture
```

⚠️ These are forwarded into the container by name. `docker exec` does not inherit
the caller's environment, so a variable the launcher does not forward is silently
ignored from the host while working inside the container — set them on the
`./uis` command line as above and they will arrive.

**There is deliberately no fixture template in the registry.** It was considered
and declined on 2026-09-09: the registry is what `uis template list` shows a
user, so anything in it is something someone may install, and a fixture whose
purpose is to exercise edge cases is not that. The local override above covers
the testing need it would have served, and an example belongs in documentation —
where it can be read without being installable.

### Multi-instance services, and the order of operations

`./uis deploy` receives `--app <app_name>` automatically for any service whose
`multiInstance` is true in `services.json` (today: `postgrest`). `configure`
always receives `--app`, because a single-instance service can still hold
per-app resources — `configure postgresql --app` creates a per-app database in
the shared instance.

⚠️ **Which runs first is per-service, and the install prints it.** It follows
from what multi-instance means:

| | order | why |
|---|---|---|
| single-instance | **deploy, then configure** | the service is shared and already running; `configure postgresql` execs into the running pod |
| multi-instance | **configure, then deploy `--app`** | `deploy --app` *creates* the per-app instance and consumes what configure produced. `configure` cannot want the instance running, because it does not exist yet |

A multi-instance service declared with **no** `config:` is rejected: a per-app
instance would have nothing to consume.

:::warning A template does not yet cover every surface
A **web frontend** has no service to declare: `webapp` — a multi-instance
Deployment + Service + IngressRoute — is Phase 5 of
[PLAN-templates-002](../ai-developer/plans/backlog/PLAN-templates-002-application-catalogue.md)
and is not built. An application whose frontend is a container image still
deploys that half through ArgoCD, which is the documented path for workloads
anyway; only the *route* is missing from `provides:`.
:::

---

## Secrets Management

| Command | Description |
|---------|-------------|
| `./uis secrets init` | Create `.uis.secrets/` directory with templates |
| `./uis secrets status` | Show which secrets are configured vs missing |
| `./uis secrets edit` | Open secrets config in editor |
| `./uis secrets generate` | Generate Kubernetes secrets from templates |
| `./uis secrets apply` | Apply generated secrets to the cluster |
| `./uis secrets validate` | Validate secrets config and check required values |

## Testing

| Command | Description |
|---------|-------------|
| `./uis test-all` | Deploy and undeploy all services (full integration test) |
| `./uis test-all --dry-run` | Show test plan without executing |
| `./uis test-all --clean` | Undeploy everything first, then run tests |
| `./uis test-all --only <svc> [svc...]` | Test only specified services and their dependencies |

## Service-Specific Commands

### Tailscale and Cloudflare

Tailscale and Cloudflare are managed through the unified [`uis network`](#network-management) family. The legacy `uis tailscale <verb>` and `uis cloudflare <verb>` invocations print a redirect stub and exit non-zero.

### ArgoCD

| Command | Description |
|---------|-------------|
| `./uis argocd register <name> <repo-url>` | Register a GitHub repo as ArgoCD application. Name is used as namespace, repo-url must be full HTTPS URL |
| `./uis argocd remove <name>` | Remove an ArgoCD application and its namespace |
| `./uis argocd list` | List registered ArgoCD applications with health and sync status |
| `./uis argocd verify` | Run ArgoCD health checks |

## Host Configuration

Manage configurations for different deployment targets.

| Command | Description |
|---------|-------------|
| `./uis host add` | List available host templates |
| `./uis host add <template-id>` | Add a host configuration from template |
| `./uis host list` | List configured hosts with status |

## Other Commands

| Command | Description |
|---------|-------------|
| `./uis init` | First-time setup wizard (cluster type, domain, project name) |
| `./uis setup` | Interactive TUI menu for browsing and deploying services |
| `./uis tools list` | List optional tools with installation status. See [Tools](./tools.md). |
| `./uis tools install <tool-id>` | Install an optional tool (aws-cli, azure-cli, etc.). See [Tools](./tools.md). |
| `./uis docs generate [dir]` | Generate JSON data files for website documentation |
| `./uis version` | Show UIS version |
| `./uis help` | Show help |

## Environment Variables

| Variable | Purpose | Default |
|----------|---------|---------|
| `UIS_IMAGE` | Override container image | `ghcr.io/helpers-no/uis-provision-host:latest` |
| `UIS_KUBECONFIG_DIR` | Override kubeconfig directory | `$HOME/.kube` |
