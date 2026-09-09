# Plan: install an application from the catalogue, in one command

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Backlog — Phases 1-4 shipped (1.6.17-1.6.23) and verified on a cluster by
`imac` (`urb-agents#367`); Phase 5 and 6.2 open (6.1 done in 1.6.24). Phase 5 (`webapp`) waits on the Atlas
frontend actually needing it.

**Goal**: `./uis template install <application>` installs an application on any UIS
installation from a catalogue entry, in one command, with the install definition
owned by the application and pinned to an immutable artifact.

**Input**: `INVESTIGATE-application-catalogue` (urb-agents), a design Terje has
reviewed — now at **rev 4**, which changed how the definition is fetched; this plan
is amended to match (see *Amendment* below). It answers **TPL-Q3** — yes, and
supersedes the hold filed as `urb-agents#354`, now closed.

**Parent**: [INVESTIGATE-templates-multi-surface-application](./INVESTIGATE-templates-multi-surface-application.md)
— this closes **TPL-F5** and **TPL-Q1/Q2**. **TPL-F7 is already shipped** (1.6.8);
see *Already done* below.

**Scope**: the UIS half of the spec's §9 only. The catalogue entry shape, the
registry generator and the website's two lists are `dev-templates`, not this plan
— what the generator must emit for the two sides to meet is stated in
*The seam* below.

---

## Amendment, 2026-09-09 — the definition is its own OCI artifact

Terje decided (`urb-agents#361`), after reading my answers on `#358`:

| | before | after |
|---|---|---|
| where the definition lives | inside the application's image, at `path` | **its own OCI artifact**, `<image>/uis`, at the same tag |
| how UIS fetches it | pod from the image + `kubectl cp` (my proposal) | **`oras pull`** on the provision host — no pod, no docker, no cluster |
| source forms | image **and** git | **one**: `{ artifact, tag, digest }` |
| the pin | tag | **digest**; the tag is shown, the digest is pulled |
| `oras` | — | in `Dockerfile.uis-provision-host` |

🔴 **My cluster-pod proposal is superseded, and it was the weaker answer.** Two things
I should have weighed and did not:

- **a pod is a fetch through a scheduler.** Pending, image-pull backoff, eviction, a
  node with no capacity — each becomes a way for `template install` to fail *before
  it has installed anything*. I reused an existing credential path and never priced
  the failure surface I was adding alongside it.
- **I optimised retrieval instead of questioning the premise.** Pulling a whole image
  to read a few kilobytes of YAML was the cost of putting the definition *in* the
  image, and nothing needed it there. I took that from the spec as given — the same
  reasoning-from-a-shape I have been correcting all week, arriving as an omission
  rather than an error.

What survives from my side is the credential finding, and it is why the private case
stays free: `oras login` uses `GITHUB_USERNAME`/`GITHUB_ACCESS_TOKEN`, verified at
`00-common-values.env.template:139-140` and built into `ghcr-credentials` at
`00-master-secrets.yml.template:216-229`.

---

## 🔴 Three places the spec's shape is wrong against the code

The spec is a design; these are facts, measured on `main` at 1.6.14.

### 1. There is no docker on the provision host — and the fetch is now an OCI artifact

**Superseded by Terje's decision of 2026-09-09 (`urb-agents#361`), which is better than
what I proposed.** Kept because the finding underneath it still stands and explains
why the design changed.

The finding: §7 step 2 said *image form → `docker pull` the pinned tag, `docker
create`, copy `path` out*, and open question 2 said *"start with docker; it is
there."* **It is not.** `Dockerfile.uis-provision-host` installs no docker client
and the launcher mounts no `/var/run/docker.sock`, so neither CLI nor daemon is
reachable from where `template.sh` runs.

I proposed resolving through the cluster — a pod from the pinned image, `kubectl
cp` the path out. **Terje's answer removes the need to resolve an image at all:**

> the application publishes its install definition as **its own OCI artifact**,
> beside its image, at the same tag — `oras push ghcr.io/<owner>/<image>/uis:<tag>`
> with `template-info.yaml` and its files. UIS fetches it with `oras pull`. No pod,
> no docker, no cluster for the fetch.

Two reasons it is better than my proposal, and both are things I should have weighed:

- **a pod is a fetch through a scheduler.** Everything the scheduler can do wrong —
  pending, image-pull backoff, eviction, a node with no capacity — becomes a way
  for `template install` to fail *before it has installed anything*. I was reusing
  an existing credential path and did not price the failure surface I was adding.
- **pulling a whole image to read a text file was the cost of putting the
  definition inside the image, and nothing needed it there.** The artifact is a few
  kilobytes. I took "the definition lives in the image" as given from the spec and
  optimised the retrieval instead of questioning the premise.

✅ **Verified, since the credential path is what my proposal was built on:**
`GITHUB_USERNAME` and `GITHUB_ACCESS_TOKEN` are in
`00-common-values.env.template:139-140`, and `00-master-secrets.yml.template:216-229`
builds `ghcr-credentials` from exactly that pair. So `oras login ghcr.io` uses a
credential the installation already has, and the private-artifact requirement stays
free — which was the one good half of my proposal and it survives.

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
| **2** | `docker create` or `oras`? | **`oras`, on a separate artifact — Terje, `#361`.** No docker exists on the provision host, and the question dissolves once the definition is not inside the image. `oras` goes into `Dockerfile.uis-provision-host` |
| **3** | Where do `exports` come from? | **The proposal is right and the data already exists.** `configure postgrest --json` emits `public_url_prefix` and `in_cluster_url`; `configure postgresql --json` emits `database`, `username`, `secret_name`, `secret_namespace`, `env_var`. Install parses the JSON it already captures and records the named exports. No handler change needed for the first application |
| **4** | `webapp`: generic service or wrapper? | **Generic multi-instance service, PostgREST-shaped** — see §3 above |

## The seam — what the generator must emit for the two sides to meet

Stated here so it can go to Terje without a second round. For each `kind: application`
entry the registry must carry:

| field | why UIS needs it |
|---|---|
| the discriminator (`templateKind: application` or equivalent) | install refuses a non-installable kind before fetching anything |
| `source.artifact` | the OCI artifact, `<image>/uis`. **One form** — the git form is dropped (`#361`) |
| `source.tag` | what the pin was published as; shown to a human, never pulled by |
| `source.digest` | 🔴 **what UIS actually pulls.** Tags are mutable at a registry; digests are not |
| `visibility: public\|private` | decides whether the pull needs `oras login`, and lets the error name the secret rather than the URL |
| the display fields, resolved at the pin | so `template list`/`info` and the website describe what an install will actually get |

⚠️ **UIS re-validates on its own side, and digest-pinning makes that stronger rather
than redundant.** It refuses an entry with no digest, and refuses one whose `tag` no
longer resolves to the recorded `digest` — which catches a tag re-pointed at a
different artifact after the catalogue build, the one thing a build-time check
structurally cannot see.

## Phases

### Phase 1 — pointer resolution and the allowlist

- [x] 1.1 Allowlist check: `ghcr.io/helpers-no/*`, `ghcr.io/terchris/*`, configurable
      via `.uis.extend/`. Refuse anything else, naming the value and the allowlist
- [x] 1.2 Immutability check: refuse `latest`, refuse a bare branch name, require
      `v<date>-<sha>` shape for images. Same rule the Dagster code-location
      validator already applies, and it should share the message wording
- [x] 1.3 Fetch with `oras pull <artifact>@<digest>` into the cache. **Public:
      anonymous — the platform token is never touched.** Private: `oras login
      ghcr.io` with `GITHUB_USERNAME`/`GITHUB_ACCESS_TOKEN` from the master secrets
      (verified present, and the same pair that becomes `ghcr-credentials`). When
      they are missing, **name the secret, not the URL**
- [x] 1.4 `oras` into `Dockerfile.uis-provision-host`. ⚠️ `build-uis-container.yml`
      rebuilds and `./uis pull` delivers it, so no new update path — **but the docs
      must say that installing an application needs a provision host from after
      that build**, because the failure otherwise is `oras: not found` on a machine
      whose `./uis version` looks current
- [x] 1.5 Cache under `/tmp/uis-templates/<id>/<digest>`. ⚠️ Keyed by **digest** now,
      which makes the cache correct by construction: two pins cannot collide. And
      **do not `rm -rf` a shared parent** — the current fixed-path `rm -rf` made two
      concurrent installs clobber each other (imac, `#335`)
- [x] 1.6 Unit tests with `oras --from-oci-layout` against a layout on disk: **no
      network, no cluster.** A private-artifact fixture is one `oras push`
- [ ] 1.7 ~~Git-form resolution~~ — **dropped (`#361`).** One source form. Publishing
      an artifact is one command from CI or a laptop, so a second code path buys
      nothing; and it would have been a second immutability rule (`ref` vs `digest`)
      to keep in step, which is the hazard this repository keeps meeting

### Phase 2 — `--dry-run`

- [x] 2.1 Print every `uis deploy|configure` that would run, in order, with resolved
      params, and run nothing
- [x] 2.2 ⚠️ Resolution still happens *before* the plan can be printed, so
      `--dry-run` fetches the artifact. Say so in the output: it is a dry run of the
      *install*, not of the *fetch*. ✅ **But it no longer needs a cluster** — that
      was a cost of my pod proposal and Terje's decision removes it
- [x] 2.3 Falsification 1 is this phase's acceptance

### Phase 3 — the code-location entry (TPL-F5)

- [x] 3.1 A `provides` entry may contribute a `code_location` to
      `.uis.extend/dagster-code-locations.yaml`, then run `uis deploy dagster`
- [x] 3.2 Idempotent: re-installing at the same pin rewrites the same entry and
      changes nothing. A new pin rolls the tag — which the Dagster playbook already
      handles, since Helm rolls only when the image field changes
- [x] 3.3 ⚠️ **Answer TPL-Q1/Q2 in this phase, not before**: whether this is a
      generic "contribute to another service's extend file" mechanism or a
      code-location special case. Two other files would qualify
      (`prometheus-targets.yaml`, `monitors.yaml`), so the generic form is tempting
      — and the spec needs only the specific one. Prefer specific until a second
      consumer exists

### Phase 4 — `requires` / `exports` / `applications.yaml`

- [x] 4.1 Record installed applications, their pin and their exports in
      `.uis.extend/applications.yaml`
- [x] 4.2 `requires:` is checked at install and **refuses**, naming the missing
      application and the command that installs it. Never auto-install
- [x] 4.3 `exports:` resolved from handler `--json` output (see §11 answer 3) and
      substituted as `{{ requires.<id>.<name> }}`
- [x] 4.4 `uis template remove <id>` — the inverse, refusing while another installed
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

- [x] 6.1 Extend the CLI reference: the catalogue, the source/pin/allowlist,
      `--dry-run`, `code_location`, `requires`/`exports`, `applications.yaml`
      (1.6.24). ⚠️ `webapp` is not in it because it does not exist — and the
      stale admonition saying a code location *cannot* be declared was still
      there two versions after Phase 3 shipped, which is how the unreachable
      `remove` refusal was found
- [ ] 6.2 A service page for `webapp`
- [ ] 6.3 ⚠️ Version bump in the same PR as any shipped phase — the guard enforces it

## Acceptance — the spec's §10, unchanged

All six falsifications are this plan's acceptance criteria. Two notes on how they
are met:

- 🔴 **Four of the six need a cluster, and I do not test my own work.** Each phase
  lands with the unit tests it can carry, and the falsification is a tester task.
  **Four, not five** — `--dry-run` and pointer resolution both come off the cluster
  with `oras --from-oci-layout` (`#361`).
- ✅ **The private-artifact falsification is now cheap.** It needed a private *image*,
  which nothing in this fleet has; it needs a private **artifact**, which is one
  `oras push`. That was the acceptance risk I flagged, and the decision removed it.
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
