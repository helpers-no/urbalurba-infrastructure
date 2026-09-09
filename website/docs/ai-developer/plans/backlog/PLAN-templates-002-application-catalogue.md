# Plan: install an application from the catalogue, in one command

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Backlog — Phases 1-4 shipped (1.6.17-1.6.23) and verified on a cluster by
`imac` (`urb-agents#367`); phases 1-4 falsified on a cluster including `remove` and the published catalogue (imac, #481/#487); three assertions open in round 3. Phase 5 and 6.2 open. Phase 5 (`webapp`) waits on the Atlas
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

🔴 **CORRECTION, 2026-09-09 — half of this was never true, and the argument was
wrong anyway.** What UIS actually does is refuse an entry with **no** digest and
refuse a malformed one (`_template_pin_is_immutable`). It does **not** resolve
the tag and compare — `_resolve_definition` pulls `artifact@digest` and never
looks at the tag. I asserted that second check to `dev-templates` on
`urb-agents#479` as the complement to their build step, reading it off this
paragraph rather than off the code. Eighth instance of the class in
[PLAN-system-error-paths-audit](./PLAN-system-error-paths-audit.md), and the
first I have committed **in an argument about a security property**.

⚠️ **And `dev-templates` showed the check would be useless where it matters.**
Their argument (`#479` §2), which I accept in full:

> If the catalogue *resolves* the tag on every build, the recorded digest tracks
> the tag — so a tag re-point gets automatically blessed. `t0` tag `v1` → `A`,
> recorded `A`. `t1` attacker re-points `v1` → `B`. `t2` **any** docs build
> re-resolves and records `B`. `t3` UIS installs: `v1` resolves to `B`, recorded
> digest is `B`, the check passes, `B` runs as database owner.

Their `t2` holds against this repository's code: `_fetch_registry` curls
`REGISTRY_URL_PRIMARY` — `raw.githubusercontent.com/helpers-no/dev-templates/main/…`
— with a one-hour cache. **UIS always reads the latest published registry and
pins no version of it**, so an unrelated docs build is enough to launder a
re-point, and no install-time comparison can tell.

**Where the property actually lives:** pulling by digest gives *integrity* — you
get what the digest names. It does not give *provenance* — that the digest is
one a human approved. Provenance can only be established where the digest is
authored. So resolution must be an **authoring** step with the digest committed
and reviewable in a diff, the catalogue build must **not** re-resolve, and
liveness (does the tag still point where it did?) belongs in a separate
non-gating alarm. That is `dev-templates`' model and it is the correct one.

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

## Verified against the first real application, 2026-09-09

`atlas` published its install definition as an OCI artifact
(`ghcr.io/terchris/atlas-data/uis:v20260909-4b11f3f`,
`sha256:a378a57d…dab72ec`). The whole resolution path was then run on the build
host against that real digest — no cluster, no catalogue entry, using
`REGISTRY_URL_PRIMARY=file://` and a one-entry registry.

| | how it was established |
|---|---|
| the artifact pulls, by digest | `oras pull` at v1.3.4, checksum-matched to the pin in `provision-host-02-kubetools.sh` |
| `init:` resolves from the artifact root | `uis/init/001_bootstrap.sql` lands where `$template_dir/$init` looks |
| the odd layer shape is harmless | layer 1 declares `...layer.v1.tar` over **raw YAML**; `oras` writes it by title, and nothing in UIS reads layer titles as paths |
| ordering | 30 → 50 → 56, postgrest **configure-then-deploy** because the per-app instance does not exist until deploy |
| `{{ params.* }}` substitution | `atlas-data`, `atlas-database-db`, `http://api-atlas.localhost` |
| code-location idempotency at a pin | generated entry byte-identical on re-write |
| `list` and `info` | both show the entry, `info` shows the pin |

⚠️ **This is not the acceptance below.** Everything above is resolution and
planning; nothing was deployed or configured. It narrows the cluster
falsification (`urb-agents#481`, `imac`) to the deploy/configure half rather
than replacing it.

🔴 **Two questions `atlas` could not answer and neither could I until `oras` was
on this host.** Both of us had read the artifact's *blobs* and neither had run
the *pull* — the layer-shape question was live precisely because layer 1's
declared media type disagrees with its content. Reading a blob is not running a
fetcher, and the gap between those two is where the day's other defects lived.

## Cluster falsification, round 1 — imac, 2026-09-09 (`urb-agents#481`)

Installed as a **parallel tenant** against atlas's real published artifact. The
plan matched the build-host dry-run **step for step, all seven, unmodified.**

| item | result |
|---|---|
| 1. completes | ✅ `EXIT=0` |
| 2. install-time guarantee | ✅ `api_v1` exists, `USAGE` granted, the `#308` `FOR ROLE` default-ACL entry present on a real application, **0 objects**, PostgREST `HTTP 200` with zero endpoints — correct, Dagster owns the 51 migrations |
| 3. the seam | ✅ `atlast-database-db` in `dagster`, key `DATABASE_URL` |
| 4. code location | ✅ literal `atlast-data`, **zero `{{` in the file**, visible in the workspace |
| 5. the record | ✅ pin, three services, code location, export |
| 6. convergence | ✅ **and Dagster does not roll** — file md5 unchanged, deploy generation 1, *same pod, older* (4m8s → 9m18s), workspace ConfigMap `resourceVersion` unchanged |
| 7. removal | 🔴 **not run** — see below |

🔴 **Item 7 was stopped at the confirmation prompt, correctly.** The remove plan
named `postgrest --app atlas` — the **live tenant serving 13 views** — because
removal reconstructed per-app names from the record id rather than the recorded
`app_name`. Fixed in 1.6.29; the analysis is in
[PLAN-system-error-paths-audit](./PLAN-system-error-paths-audit.md) under *A
neighbouring class*. **The prompt was the only thing between this and an
outage**, which is an argument for keeping it un-bypassable on anything that
undeploys.

Also found in that round, both fixed in 1.6.29: a hyphenated `--param
app_name=` could not create its database (identifier unquoted, and the role was
left orphaned when it failed), and the catalogue fixture's own printed commands
could not run.

**What the round establishes for this plan:** phases 1–4 are falsified on a
cluster against a real tenant artifact, except `template remove`, which is
round 2.

## Cluster falsification, round 2 — imac, 2026-09-09 (`urb-agents#481`, `#487`)

🟢 **The defect round 1 stopped at the prompt is fixed and verified.** The remove
plan names the tenant (`postgrest --app atlast`), never the live instance, and
the record carries `app_name`. **Item 7 passes in full**: code location gone,
per-app instance undeployed, **database and roles kept**, record forgotten,
`EXIT=0`.

🟢 **Installed from the PUBLISHED catalogue**, not a staged file (`#487`, after
`dev-templates` shipped the entry): plan identical to the staged one, `EXIT=0`,
`api_v1` granted, API answering empty, Secret and code location correct, record
pinned to the published digest. **`remove --purge --yes` closed cleanly** —
`dropped: atlast_authenticator, atlast_web_anon`, `removed: atlast-postgrest`.

🔴 **Two defects found, both fixed in 1.6.31, both awaiting round 3:**

| | |
|---|---|
| a *successful* re-install reported as a failure | diagnostics were on **stdout**, so a rotation warning corrupted the `--json` document. See [PLAN-system-error-paths-audit](./PLAN-system-error-paths-audit.md), instance twelve |
| `--param app_name=atlas-t` failed one step after 1.6.29 fixed it | `postgrest` re-derived the database name instead of being told it |

**Live `atlas` byte-identical at the top and bottom of every round** — 13/13
`api_v1` views, 122 `brreg_enheter` rows, postgrest restarts unchanged, across
ten `uis deploy dagster` runs in total.

**What remains for this plan's acceptance:** re-install convergence, the
hyphenated `app_name`, and one re-read of the removal plan. Everything else in
§10 that does not need `webapp` is falsified.

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
