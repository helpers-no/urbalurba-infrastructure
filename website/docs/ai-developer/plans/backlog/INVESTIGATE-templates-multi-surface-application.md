# Investigate: install an application that spans several services, from one declaration

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: Let one declaration install an application that needs *several* platform
surfaces at once — a database with migrations, a Dagster code location, and a
per-app PostgREST instance — so that installing it is one command and one
reviewable file rather than four steps a human must sequence correctly.

**Origin**: `urb-agents#159`, a design question from the **atlas** agent. Terje's
requirement, verbatim:

> "my goal is that we can install atlas on uis just like we install a service.
> atlas must use the dagster and postgres services that are in UIS and set these
> up. it must use the config system that we already have in UIS."

**Related**:
- [ANALYSIS-nais-uis](./ANALYSIS-nais-uis.md) — §2.1 names this gap ("UIS has no
  workload abstraction at all") and §4 item 13 prices the maximal answer to it.
  **This investigation is deliberately not that item**; see Decision 1 below.
- [INVESTIGATE-cli-stack-profiles](./INVESTIGATE-cli-stack-profiles.md) — the
  other open question about what a stack declaration should be able to say.

**Created**: 2026-09-07 — findings traced against `main` @ `6a39e0e`

**Finding IDs**: `TPL-`.

---

## Decision 1 — this is option A, and option B stays deferred

The requirement admits two shapes, and they were put to the maintainer as a
choice:

- **A** — make the application expressible in mechanisms UIS already has.
- **B** — grow an `Application` type: a first-class thing owning a code location,
  a database, secrets and an exposure, installed and verified as one.

**A is chosen. B remains deferred, on the reasoning already recorded in this
repository** — [ANALYSIS-nais-uis](./ANALYSIS-nais-uis.md) §4 ranks a UIS
`Application` manifest **last of thirteen** adoptable ideas, at **L** effort,
and says explicitly:

> "do not start it before 1, 3 and 5 have landed, because they define what it
> would need to express … The right sequence is to make the individual
> capabilities exist first (secrets, network policy, telemetry) and only then ask
> whether they deserve a single declaration. NAIS built `nais.yaml` on top of
> capabilities it already ran; UIS would be building the declaration first."

Items 1, 3 and 5 (per-workload named secrets, default-deny NetworkPolicy, OTEL
auto-instrumentation) have not landed. The precondition for opening B is unmet,
and the first real tenant arriving is an argument for finishing A, not for
jumping that queue.

### Why B could not remove the split it was proposed to remove

The question asked alongside A-versus-B was sharper than the choice itself:
*would an `Application` type **remove** the declarative/imperative split, or
merely **wrap** it?* — on the grounds that a wrapper hides a difference that will
resurface at the third surface.

Reframed correctly, the split is not declarative-versus-imperative. It is **where
the state is allowed to live**:

- A code location lives in `.uis.extend/dagster-code-locations.yaml` because it
  is installation *configuration* — image, tag, module, `why:`. Nothing about it
  is secret, so a file is the right home.
- A PostgREST app's configuration lives in the **cluster** — a Secret plus two
  Postgres roles — because it contains a generated password that
  `configure-postgresql.sh:237` is commented, deliberately, *"2UIS — UIS does not
  store this."*

An `Application` type cannot move the second into a file without breaking that
rule. It could therefore only ever **wrap** the split. By the test as posed, B
fails it. This is recorded here because it is the strongest single argument
against B and it should not have to be rediscovered.

---

## Decision 2 — the unit above a service already exists, and is called a template

`provision-host/uis/lib/template.sh` already implements deploy-plus-configure
across several services under one name and one `app_name`:

- `template-info.yaml` declares `install_type: stack`, a `provides:` list, and a
  `params:` block
- `_resolve_provides` (`template.sh:199-270`) expands `provides.stacks[]` via
  `stacks.json` and `provides.services[]`, deduplicates, and orders by each
  service's `priority` from `services.json`
- `cmd_template_install` (`template.sh:299-...`) walks that plan, deploying then
  configuring, substituting `{{ params.* }}` into both the database name and the
  init-file *contents*

That is option B's shape without the CRD, already shipped and already tested.
**The work is to extend it, not to design a new concept.** This is the finding
that makes A small.

---

## Part 1 — what the four manual steps actually are

Installing the first real tenant today takes four steps. The premise handed to
the maintainer said two of them were undefined; **that premise was wrong, and
correcting it is most of the value of this investigation.**

| Step | Claimed | Actual |
|---|---|---|
| 1. database + owning role | "nothing defines this" | ✅ `uis configure postgresql --app <n> --database <d> --init-file -` creates both, applies migrations from stdin, and **rolls back** if the init file fails (`configure-postgresql.sh:244-300`) |
| 2. secret in the `dagster` namespace | "UIS explicitly does not" | ✅ `--namespace` + `--secret-name-prefix` (`configure.sh:104-110`) ensures the namespace and writes the Secret idempotently (`configure-postgresql.sh:110-133`) |
| 3. code location | declarative, hand-edited file | ⚠️ correct — **nothing writes it**; see TPL-F3 |
| 4. per-app PostgREST | imperative command | ✅ correct, and already app-shaped: `SCRIPT_MULTI_INSTANCE="true"` since it shipped |

**TPL-F1 — steps 1 and 2 are one command, and no tenant has used it.** The
`--namespace`/`--secret-name-prefix` pair was built for exactly this and went
unused by the first application it was built for, because the Dagster tenant
documentation said the opposite. Fixed in this branch; recorded here as the cause.

**TPL-F2 — nothing anywhere expresses that the four belong to one application.**
This is the real gap, and it is the only part of the original problem statement
that survives scrutiny.

---

## Part 2 — why `uis template install` cannot install this tenant today

Four blockers, all small and all specific.

**TPL-F3 — a template cannot deploy a multi-instance service.**
`template.sh:405` calls:

```bash
uis deploy "$svc"
```

with **no `--app`**. The configure call two lines later *does* pass
`--app "$app_name"`. So a template can configure a per-app instance and then fail
to deploy it — the halves disagree. For PostgREST, whose every instance is
per-app, the template path is unusable.

**TPL-F4 — `config:` carries only two of the five fields needed.**
`_resolve_provides` reads `config.database` and `config.init` and nothing else.
Missing: `schemas` and `url_prefix` (PostgREST), and `namespace` +
`secret_name_prefix` (the step-2 secret). Every one of these already exists as a
`uis configure` flag; none is reachable from a declaration.

**TPL-F5 — no `provides:` entry can express a Dagster code location.**
The code location is not a service to deploy and configure; it is a line appended
to `.uis.extend/dagster-code-locations.yaml` followed by `uis deploy dagster`. A
template has no vocabulary for "contribute an entry to another service's
`.uis.extend` declaration", and no code anywhere writes that file.

**TPL-F6 — a template must live in another repository.**
`REGISTRY_URL_PRIMARY` (`template.sh:16`) points at
`helpers-no/dev-templates`, and `_fetch_template_folder` sparse-clones from
there. An application therefore cannot ship its own installer beside its own
code, which is the natural place for it and the only place its author can keep it
in step with the image they publish.

---

## Part 3 — open questions

**TPL-Q1 — does a code-location entry belong in `provides:` at all?**
It is a contribution to another service's declaration, not an instance of a
service. Two shapes to weigh: a `provides.code_locations[]` list beside
`provides.services[]`, or a generalised "this template contributes to
`.uis.extend/<file>`" mechanism. The second is more powerful and much easier to
get wrong; `prometheus-targets.yaml`, `monitors.yaml` and `external-services.yaml`
are the other files that would qualify, so the generalisation is not theoretical.

**TPL-Q2 — who owns idempotency and removal of a contributed entry?**
`uis deploy dagster` prunes code-location objects Helm will not prune
(`360-setup-dagster.yml:398`) and asserts the cluster matches the declaration
(`:475`). So the declaration is authoritative and reinstalling is safe — *if* the
writer is idempotent. What should `uis template remove <id>` do: drop the entry
and redeploy Dagster, or refuse and print what to remove? Note `uis stack remove`
exists as a precedent to match.

**TPL-Q3 — may a template ship from the application's own repository?**
Resolving TPL-F6 means fetching a `template-info.yaml` from an arbitrary repo and
then executing the deploy/configure plan it describes, including piping its
init-file contents into `psql`. That is a supply-chain decision, not a
convenience one. Options: keep the central registry and require a PR; allow a
pinned `owner/repo@sha`; allow a local path only. **This question is the one most
likely to need Terje rather than the maintainer.**

**TPL-Q4 — should `provides:` be able to name a verify step?**
An application with no data can look completely healthy: code location `LOADED`,
API answering, views present, zero rows — the failure mode this platform keeps
meeting. The boundary that seems right is *the platform verifies the pipe, the
tenant verifies the data*: `uis verify postgrest --app <n>`
(`088-test-postgrest.yml`) already proves the whole pipe using a probe table it
creates and drops, so it can neither be fooled by an empty tenant nor corrupt a
full one; the tenant's own freshness check proves the data. If a template can
compose the two, `uis verify <app>` need not exist.

The tenant proposed a `verify:` block naming both halves, and argued the tenant half must be able
to **fail** the verify — otherwise an install with a `LOADED` code location, an answering API and
zero rows passes.

🔴 **But they then found the problem with their own proposal, and it is the real question here: on a
first install the tenant's data check legitimately fails, because no ingest has run yet.** A verify
that reds on a correct install is worse than no verify — it trains people to ignore it.

**Provisional answer, for the plan to accept or reject: "the install worked" and "data is flowing"
are two different assertions and should not be one command.** Freshness is not a verify at all — it
is a **monitor**, and UIS already has that convention queued rather than absent
(`.uis.extend/monitors.yaml` and `lib/monitors.py`;
[PLAN-system-observability-006-service-probes](./PLAN-system-observability-006-service-probes.md);
[INVESTIGATE-system-monitor-definitions-with-services](./INVESTIGATE-system-monitor-definitions-with-services.md)).
A monitor that is red between install and first ingest is *correct and visible*; a verify that is
red there is a bug. That reframing dissolves the first-install paradox instead of special-casing
it — and it means what a template should ship is a **monitor** alongside its services, which is the
artifact convention those two documents are already deciding. **Do not settle TPL-Q4 before that
convention is settled**; it is the third consumer of it, exactly as Tier 3 #20 warns.

**TPL-Q5 — is `install_type: stack` still the right discriminator?**
`_validate_template_info` hard-rejects anything but `stack`. If an application
template is a different kind of thing, this is where that would be expressed —
or the field is redundant and should be dropped rather than extended.

---

## Part 4 — what "done" looks like

One file, in the application's own idiom, that expresses: a database with these
migrations; a Dagster code location at this image, tag and module with this
`why:`; and PostgREST over these schemas at this URL prefix. Then:

```bash
./uis template install atlas
```

and an acceptance test the platform can run unattended:

> A request issued **from a second machine on the same LAN** returns the
> application's rows from the cluster.

⚠️ **That last line is not a UIS feature and no work here should try to make it
one.** Traefik already routes every app on ``HostRegexp(`<prefix>\..+`)``
(`templates/088-postgrest-ingressroute.yml.j2`), which matches any suffix, so
reaching it from another machine on the LAN needs a Host header and a name that
resolves — a hosts entry — and no platform change. PostgREST also already sets
`PGRST_SERVER_CORS_ALLOWED_ORIGINS: "*"`
(`templates/088-postgrest-config.yml.j2:75`), so a browser front-end calling
cross-origin is not blocked. This follows the precedent set when
[INVESTIGATE-system-roaming-dependency-addresses](../completed/INVESTIGATE-system-roaming-dependency-addresses.md)
was closed with the ruling that the endpoint manager was *"installation
implementation, not UIS"*.

The one thing genuinely unmeasured is whether a given installation's Traefik
accepts connections on its LAN interface rather than only on loopback. That is a
property of how the cluster is run on that host. **If it turns out to be
loopback-only, that is a real platform question and belongs in a new
investigation, not folded in here.**

---

## Part 4b — the tenant's declaration, and two blockers it exposed

The application author supplied the declaration they *want* to write (`urb-agents#159`,
2026-09-07). It is reproduced here as the requirements section: the point of option A is that this
file is the specification, not UIS's guess at one.

```yaml
install_type: stack
params:
  app_name: atlas

provides:
  - service: postgresql
    config:
      database: "{{ params.app_name }}"
      namespace: dagster
      secret_name_prefix: "{{ params.app_name }}-database"
      init: migrations/            # 49 numbered DDL files creating raw.*

  - service: dagster
    config:
      code_location:
        name: "{{ params.app_name }}-data"
        image: ghcr.io/terchris/atlas-data
        tag: <immutable; never :latest>
        module: atlas_data.definitions
        why: "Atlas ingest and dbt transforms; without it marts.* and api_v1 stop refreshing"
        env_secrets: ["{{ params.app_name }}-database-db"]

  - service: postgrest
    config:
      app: "{{ params.app_name }}"
      schemas: <pending — see below>
      url_prefix: api-atlas
```

Confirmed against the tenant: the code location reads `DATABASE_URL` (with a fallback), so
**`configure postgresql`'s hardcoded key is accepted and no `--secret-key` flag is needed.** That
closes one option from the doc-fork question. The author also wrote `atlas-database-db` out
literally rather than templating it, because the `-db` suffix is the trap.

⚠️ **`schemas:` is deliberately unfilled.** The running instance serves `api_v1`; `PLAN-007`
shipped `api_v1,marts,raw` at this tenant's request and the consuming frontend renders endpoints
across all three; the anon role has no `USAGE` on the other two, so widening is a re-configure and
not a flag change. **That value is a product decision, not a design one.**

### TPL-F7 — `init:` accepts one file, and this tenant has a directory of 49

`template.sh:424-431` resolves `init` to a single path, rejects it with *"Init file not found"* if
`[[ ! -f ]]`, and `cat`s it into `uis configure --init-file -`. **A directory fails outright.**

Real DDL arrives as ordered numbered files, so this is not specific to one tenant. Whatever fixes
it must preserve **apply order** — concatenating in sorted order is probably right, and is a
decision rather than an implementation detail, because a partial apply is what
`configure-postgresql`'s rollback exists to undo.

### TPL-F8 — 🔴 priority order cannot express an intra-application dependency, and it breaks this install

The author asked whether `provides:` executes in **declaration order** or **service-priority
order**. Measured: `_resolve_provides` (`template.sh:262-268`) reads each service's `priority` from
`services.json` and `sort -t'|' -k1,1n`. **Priority order. Declaration order is discarded.**

The priorities:

| service | priority |
|---|---|
| postgresql | 30 |
| **postgrest** | **50** |
| **dagster** | **56** |

The tenant needs `postgresql → dagster → postgrest`. **Priority order inverts the last two.**

And this is not a cosmetic reordering — it is a hard failure. `api_v1` does not exist until a
transform has run at least once, and `configure-postgrest.sh:303` **refuses when a named schema is
absent**:

> "Schema '<s>' does not exist in database '<db>'. Create it first (typically via the consuming
> app's migration), then retry"

So `uis template install atlas` would deploy PostgreSQL, then fail configuring PostgREST, having
never reached Dagster. **The first real application cannot be installed in priority order at all.**

This is a design finding, not a bug to patch by renumbering. Service priority expresses *platform
boot order* — a global property of a service. What this needs is *intra-application* ordering, which
is a property of one declaration. Renumbering `dagster` below `postgrest` would satisfy this tenant
and mis-state the platform. Options for the plan to weigh: honour declaration order within
`provides:`; add explicit `after:` edges; or split install into phases the way the four manual steps
already are. **Whichever is chosen, TPL-F8 must be resolved before TPL-F4, because it changes what
`config:` has to mean.**

## Part 5 — proposed plan split

Not yet approved; the questions in Part 3 come first.

| Plan | Scope | Depends on |
|---|---|---|
| `PLAN-templates-000-install-ordering` | **TPL-F8**: how a declaration expresses intra-application order. Gates 001, because it changes what `config:` must mean | none — and it is the only one that blocks an install outright |
| `PLAN-templates-001-multi-instance-deploy` | TPL-F3 + TPL-F4 + TPL-F7: `--app` on the deploy call, the missing `config:` fields, and a multi-file `init:` | TPL-F8 |
| `PLAN-templates-002-code-location-contrib` | TPL-F5: a writer for `.uis.extend/dagster-code-locations.yaml` and the `provides:` vocabulary for it | TPL-Q1, TPL-Q2 |
| `PLAN-templates-003-app-owned-templates` | TPL-F6: a template shipped from the application's repository | TPL-Q3 — **needs a product ruling, not a design** |

TPL-F3 is worth fixing on its own merits regardless of what this investigation
concludes: today the deploy and configure halves of one loop disagree about
whether a service is multi-instance, which is a latent defect for any
multi-instance service, not just this tenant.

**TPL-F8 is the one that changes the shape of the answer**, which is why it is numbered 000 and not
folded into 001. Every other finding is a missing field or a missing call; F8 says the execution
model itself cannot express what one application needs, and no amount of `config:` vocabulary fixes
an install that runs its steps in the wrong order.
