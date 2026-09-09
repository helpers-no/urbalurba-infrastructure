# Plan: install an application from the catalogue, in one command

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Backlog

**Goal**: `./uis template install <application>` installs an application on any UIS
installation from a catalogue entry, in one command, with the install definition
owned by the application and pinned to an immutable artifact.

**Input**: `INVESTIGATE-application-catalogue` (urb-agents, `2992d05`), a design
Terje has reviewed. It answers **TPL-Q3** — yes, through the catalogue — and
supersedes the "may an application ship its own template" question filed as
`urb-agents#354`.

**Parent**: [INVESTIGATE-templates-multi-surface-application](./INVESTIGATE-templates-multi-surface-application.md)
— this closes **TPL-F5** and **TPL-Q1/Q2**. **TPL-F7 is already shipped** (1.6.8);
see *Already done* below.

**Scope**: the UIS half of the spec's §9 only. The catalogue entry shape, the
registry generator and the website's two lists are `dev-templates`, not this plan
— what the generator must emit for the two sides to meet is stated in
*The seam* below.

---

## 🔴 Three places the spec's shape is wrong against the code

The spec is a design; these are facts, measured on `main` at 1.6.14.

### 1. There is no docker on the provision host — the image form cannot use it

§7 step 2 says *"image form → `docker pull` the pinned tag, `docker create`, copy
`path` out"*, and open question 2 says *"start with docker; it is there."*

**It is not there.** `Dockerfile.uis-provision-host` installs no docker client, and
the launcher runs the container with `--network host --privileged` and **no
`/var/run/docker.sock` mount**. So neither the CLI nor the daemon is reachable
from where `template.sh` runs.

**Proposed instead: resolve the image pointer through the cluster.** Run a
short-lived pod from the pinned image, `kubectl cp` the `path` out, delete it.
That is strictly better than adding docker or `oras`, on grounds that are
properties of this platform rather than preferences:

- **it reuses a credential that already exists.** `ghcr-credentials` is in
  `00-master-secrets.yml.template`, applied to every namespace, and already wired
  as `imagePullSecrets` on the Dagster chart (`manifests/360-dagster-config.yaml:22`).
  So §6's *"a private one needs the installing platform's own package credential,
  held in that installation's `urbalurba-secrets`"* is satisfied by something
  shipped, with no second credential path and no token on the provision host
- **`kubectl` is certainly present**; docker certainly is not
- **it needs no new tool and no privilege escalation.** Mounting the docker socket
  into a `--privileged` container to fetch a third party's SQL is the opposite of
  what the allowlist is for
- **it costs nothing in reach.** `template install` already requires a cluster —
  it deploys services — so requiring one to resolve the pointer removes no
  capability

⚠️ **What this trades**: `--dry-run` cannot show the resolved definition without a
cluster, and an image whose entrypoint exits immediately needs a `command:`
override to stay alive for the copy. Both are handled in Phase 1.

### 2. The registry carries none of `kind`, `source` or `pin`

Fetched and read, `template-registry.json` today:

```
top:      generated, dctDocsBase, uisDocsBase, categories, templates
per entry: id name description abstract category tags version install_type
           templateKind templateRepoPath folder files filesMdx logo readme
           links maintainers prerequisites quickstart params provides related
           configureCommand architectureMdx expectedOutputBlock
           resolvedServices resolvedInitFiles resolvedTools
```

So **a generator schema change is a prerequisite**, and two things follow:

- there is already a `templateKind` **and** an `install_type`. Adding a third
  discriminator called `kind` would make three; the generator should reuse one and
  the plan should not assume a new field name
- ⚠️ **the generator already resolves and inlines** — `resolvedServices`,
  `resolvedInitFiles`, `resolvedTools`. "Resolve the pointer at the pin and write
  the metadata in" is therefore an **extension of an existing pattern**, not new
  machinery, which is the strongest argument the spec has and it does not make it

### 3. `webapp` should be postgrest-shaped, not a `whoami` wrapper

Open question 4's remainder. `whoami` is `SCRIPT_MANIFEST=""` plus a playbook, and
its manifests (`070`, `071`) are **static, single-instance, fixed-name** — a test
pod, not a template. Nothing in them parameterises.

What transfers from `whoami` is the **routing pattern** — one IngressRoute whose
`HostRegexp` covers `<name>.localhost` and `<name>.<domain>` together. What
transfers as *structure* is PostgREST: a per-app playbook plus two Jinja templates,
122 + 126 + 28 lines. So: **one generic multi-instance `webapp` service in the
PostgREST shape**, borrowing whoami's Host rule.

## Already done — do not re-implement

- **TPL-F7**, `init:` as a directory — shipped in **1.6.8**, `LC_ALL=C` ordered,
  empty-directory refusal, padding warning added in 1.6.13. Verified end-to-end by
  the tester: `apiv1.t` columns at 1/2/3 from `001_`/`026_`/`050_`. The spec lists
  it as work; it is a **requirement already met**.
- **`uis template info <id>`** — exists (`template.sh:122`). It needs *extending*
  for the new fields, not writing.
- **`TEMPLATE_REPO` / `REGISTRY_URL_*` overrides** — shipped 1.6.9, forwarded from
  the host in 1.6.10. The fixture mechanism the plan's tests need is in place.

## Answers to §11, from the code

| | Question | Answer |
|---|---|---|
| **1** | Does the registry carry `kind`/`source`/`pin`? | **No.** Schema change first. And prefer reusing `templateKind`/`install_type` over adding a third discriminator — see §2 above |
| **2** | `docker create` or `oras`? | **Neither.** No docker on the provision host at all. Resolve through the cluster with `kubectl cp` — see §1 above |
| **3** | Where do `exports` come from? | **The proposal is right and the data already exists.** `configure postgrest --json` emits `public_url_prefix` and `in_cluster_url`; `configure postgresql --json` emits `database`, `username`, `secret_name`, `secret_namespace`, `env_var`. Install parses the JSON it already captures and records the named exports. No handler change needed for the first application |
| **4** | `webapp`: generic service or wrapper? | **Generic multi-instance service, PostgREST-shaped** — see §3 above |

## The seam — what the generator must emit for the two sides to meet

Stated here so it can go to Terje without a second round. For each `kind: application`
entry the registry must carry:

| field | why UIS needs it |
|---|---|
| the discriminator (`templateKind: application` or equivalent) | install refuses a non-installable kind before fetching anything |
| `source.image` + `source.tag` + `source.path`, **or** `source.repo` + `source.ref` + `source.path` + `source.include` | the two pointer forms; UIS resolves, the generator does not inline the definition |
| `visibility: public\|private` | decides whether the pull needs `ghcr-credentials`, and lets the error name the secret rather than the URL |
| the pin, verbatim as published | UIS re-checks immutability at install; **the build refusing is not enough**, because a registry can be edited between build and install |
| the display fields, resolved at the pin | so `template list`/`info` and the website describe what an install will actually get |

⚠️ **UIS will re-validate the allowlist and immutability itself.** Not distrust of
the build — a defence-in-depth the spec's own §4 rationale ("so a merged typo
cannot point a platform at a stranger's SQL") argues for on both sides.

## Phases

### Phase 1 — pointer resolution and the allowlist

- [ ] 1.1 Allowlist check: `ghcr.io/helpers-no/*`, `ghcr.io/terchris/*`, configurable
      via `.uis.extend/`. Refuse anything else, naming the value and the allowlist
- [ ] 1.2 Immutability check: refuse `latest`, refuse a bare branch name, require
      `v<date>-<sha>` shape for images. Same rule the Dagster code-location
      validator already applies, and it should share the message wording
- [ ] 1.3 Image-form resolution via the cluster: pod from the pinned image with a
      `command:` override so it stays alive, `kubectl cp <path>`, delete. Use
      `ghcr-credentials` when `visibility: private`; when it is missing, **name the
      secret, not the URL**
- [ ] 1.4 Git-form resolution: sparse checkout of `path` + `include` at `ref`
- [ ] 1.5 Cache under `/tmp/uis-templates/<id>/<pin>`. ⚠️ Keyed by pin, and **do not
      `rm -rf` a shared parent** — the current fixed-path `rm -rf` made two
      concurrent installs clobber each other (imac, `#335`)
- [ ] 1.6 Unit tests with fixtures for both forms; the image form needs a cluster
      and is a tester task

### Phase 2 — `--dry-run`

- [ ] 2.1 Print every `uis deploy|configure` that would run, in order, with resolved
      params, and run nothing
- [ ] 2.2 ⚠️ Resolution happens *before* the plan can be printed, so `--dry-run`
      still fetches. Say so in the output: it is a dry run of the *install*, not of
      the *fetch*
- [ ] 2.3 Falsification 1 is this phase's acceptance

### Phase 3 — the code-location entry (TPL-F5)

- [ ] 3.1 A `provides` entry may contribute a `code_location` to
      `.uis.extend/dagster-code-locations.yaml`, then run `uis deploy dagster`
- [ ] 3.2 Idempotent: re-installing at the same pin rewrites the same entry and
      changes nothing. A new pin rolls the tag — which the Dagster playbook already
      handles, since Helm rolls only when the image field changes
- [ ] 3.3 ⚠️ **Answer TPL-Q1/Q2 in this phase, not before**: whether this is a
      generic "contribute to another service's extend file" mechanism or a
      code-location special case. Two other files would qualify
      (`prometheus-targets.yaml`, `monitors.yaml`), so the generic form is tempting
      — and the spec needs only the specific one. Prefer specific until a second
      consumer exists

### Phase 4 — `requires` / `exports` / `applications.yaml`

- [ ] 4.1 Record installed applications, their pin and their exports in
      `.uis.extend/applications.yaml`
- [ ] 4.2 `requires:` is checked at install and **refuses**, naming the missing
      application and the command that installs it. Never auto-install
- [ ] 4.3 `exports:` resolved from handler `--json` output (see §11 answer 3) and
      substituted as `{{ requires.<id>.<name> }}`
- [ ] 4.4 `uis template remove <id>` — the inverse, refusing while another installed
      application requires it

### Phase 5 — `webapp`, a multi-instance service

- [ ] 5.1 `service-webapp.sh` with `SCRIPT_MULTI_INSTANCE="true"`, a setup playbook
      and two Jinja templates, in the PostgREST shape
- [ ] 5.2 `deploy webapp --app <name> --image --tag [--port] [--env K=V] [--env-secret]`
      renders Deployment + Service + IngressRoute
- [ ] 5.3 One IngressRoute covering `<name>.localhost` and `<name>.<domain>` via
      `HostRegexp`, as `whoami` and every other service already do
- [ ] 5.4 `verify webapp --app <name>` curls the route, expects 2xx. ⚠️ It must
      report **which host it resolved**, or a green verify says nothing about the
      exposed domain
- [ ] 5.5 A new tag rolls the Deployment; the same tag changes nothing
- [ ] 5.6 `undeploy webapp --app <name>`

### Phase 6 — docs, and the version bump

- [ ] 6.1 Extend the CLI reference: the catalogue, both pointer forms, the
      allowlist, `--dry-run`, `requires`/`exports`, `webapp`
- [ ] 6.2 A service page for `webapp`
- [ ] 6.3 ⚠️ Version bump in the same PR as any shipped phase — the guard enforces it

## Acceptance — the spec's §10, unchanged

All six falsifications are this plan's acceptance criteria. Two notes on how they
are met:

- 🔴 **Five of the six need a cluster, and I do not test my own work.** Each phase
  lands with the unit tests it can carry, and the falsification is a tester task.
  The private-artifact one additionally needs a private image, which nothing in
  this fleet has yet — flagged now rather than discovered at acceptance.
- Falsification 2 says the install ends with *"an API that answers with an empty,
  correctly-granted `api_v1`"*. That is only true because the application's
  migrations create the schema — `CREATE SCHEMA IF NOT EXISTS api_v1`, TPL-F9. The
  platform cannot make it true alone, and the acceptance should say so.

## Out of scope

- the catalogue entry shape, the registry generator, the website's two lists —
  `dev-templates`
- the application's own definition, Dockerfile `COPY` and release step — the
  application
- ⚠️ **auto-installing a dependency.** The spec forbids it and the reason is worth
  keeping: another application's `schemas:`-type decisions are a person's, and
  `#350` is what that looks like when it is taken seriously
