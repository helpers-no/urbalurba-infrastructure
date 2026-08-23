# Ship Dagster as a UIS service — the platform data orchestrator

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog — ⚠️ AWAITING TERJE'S APPROVAL of name, category, chart version and sizing

**Decision already taken (Terje, 2026-08-22)**: Dagster becomes a **reusable UIS
orchestrator**, not an Atlas-bundled component. Atlas is the first consumer, not
the owner. Not reopened here.

**Proposed by the maintainer, for Terje to approve or change:**

| Decision | Proposal |
|---|---|
| Service name | `dagster` (upstream name, per convention) |
| Category | **`ANALYTICS`** — see reasoning below, and note it is deliberately *not* `INTEGRATION` |
| Manifest / playbook number | **`360`** — free in both ranges |
| Chart | `dagster/dagster` OSS, **pinned** to a `1.13.x` chart version |
| Namespace | `dagster` |
| Priority | `56` — after `temporal` (55), both being postgresql-dependent orchestrators |
| Concurrency ceiling | **4** simultaneous run pods (ops' open question 3) |

**Investigation**: [INVESTIGATE-service-dagster](../backlog/INVESTIGATE-service-dagster.md)
— owns the design. Written 2026-04-21, four months stale in places; reconciled below.

**Consumer requirement**: `ai-developer/for-ops-atlas-dagster-requirement.md` in
the home repo — states what Atlas needs, and explicitly does **not** own the design.

**Last Updated**: 2026-08-22

---

## ⚠️ Why UIS carries TWO orchestrators

Terje asked for this to be a deliberate choice rather than sprawl. It is, and the
distinction is not a matter of taste.

UIS already ships **Temporal** (`SCRIPT_CATEGORY="INTEGRATION"`, priority 55,
*"Durable execution engine that runs long-lived workflows reliably across crashes
and restarts"*), used by `urbalurba-platform`.

| | **Temporal** | **Dagster** |
|---|---|---|
| Orchestrates | **processes** — code that must survive failure | **data assets** — tables, files, models |
| Unit of work | a workflow execution | a materialised asset |
| Core guarantee | durable execution: a workflow resumes mid-step after a crash | lineage + freshness: what produced this table, from what, how stale is it |
| Written as | imperative workflow code (Go/Java/TS/Python SDK) | a declarative asset graph |
| Native to | long-lived business processes, sagas, human-in-the-loop | dbt, warehouses, scheduled ingest |
| Has no concept of | an asset, lineage, freshness, backfill | durable mid-step resumption |

**Could Temporal run Atlas's pipeline?** Mechanically yes — write workflows that
shell out to the ingest scripts. You would then lose the asset graph, lineage,
`dagster-dbt`'s manifest integration, freshness policies, the asset catalogue,
and backfills — and end up reimplementing Dagster inside Temporal, badly.

**Could Dagster run `urbalurba-platform`'s workloads?** Poorly. A Dagster run pod
that dies mid-step does not resume from that step with its state intact. That
durability *is* Temporal's product.

**The honest framing**: these are not two orchestrators, they are an *execution*
engine and a *data* orchestrator that happen to share the word. The clearest
evidence is that neither project positions itself against the other — Dagster
compares itself to Airflow and Prefect; Temporal compares itself to Step
Functions and Cadence.

### The boundary rule, so this does not become sprawl

> **UIS carries at most one orchestrator per shape.** Temporal owns durable
> code-first execution. Dagster owns data-asset pipelines. A third orchestrator
> needs a shape neither covers — and "we prefer its UI" is not a shape.

Airflow, Prefect, Argo Workflows and K8s CronJobs are all the *data* shape and
would be duplicates. This rule is the deliverable of the "deliberate choice"
requirement; without it, the next request has no test to fail.

**Both are optional services.** A laptop deploys neither by default. Nobody pays
for the orchestrator they do not use, which is what makes carrying two defensible
in a platform that must fit on a developer's machine.

---

## Reconciling the investigation with the consumer requirement

The two documents agree on everything structural — OSS not Dagster+, official
Helm chart, dedicated `dagster` namespace, code-locations-as-tenants, separate
metadata database on the shared Postgres, Traefik ingress, no auth day 1, K8s run
launcher. What follows is only where they diverge or where the investigation is
stale.

| # | Investigation (2026-04-21) | Requirement (2026-08-22) | Resolution |
|---|---|---|---|
| 1 | "~24 public data sources" | **41 sources**, 40 already Pipes-enabled | Requirement wins — investigation is four months stale |
| 2 | No chart version named | **`1.13.x`**, and the code-location image pins `dagster~=1.13` | **Pin it.** An unpinned chart against a pinned image is the exact shape that broke Backstage — see [PLAN-system-helm-chart-version-pinning](../backlog/PLAN-system-helm-chart-version-pinning.md) |
| 3 | Ingress `dagster.sovereignsky.no` | **Internal-only, no public ingress ever** | Requirement wins. Traefik IngressRoute, `dagster.localhost` on Rancher Desktop, tailnet on Proxmox |
| 4 | Silent on run concurrency | Asks for a ceiling; 41 sources would stampede the shared Postgres | **Propose 4** — see below |
| 5 | Silent on image size | **1.5–2 GiB** polyglot image | Real for the laptop profile. Must be called out in docs, not discovered |
| 6 | Silent on pull auth | Asks for the pattern | `ghcr-credentials` **already exists** in `00-master-secrets.yml.template` — reuse it |

**Nothing in the requirement is Atlas-shaped.** Its §6 explicitly asks to be
pushed back on. I found one thing to push back on, in *its* favour: it offers to
throttle in-code if given a ceiling, which would put platform capacity policy
inside a tenant. The cap belongs in the chart values where the platform can
change it without a tenant rebuild.

---

## Answers to the requirement's five open questions

1. **Version cadence ownership** — **UIS owns the chart version; Atlas signals
   readiness.** Neither side moves alone: Atlas rebuilds its image against the new
   Dagster line and confirms, *then* UIS bumps the pinned chart. A platform-only
   bump can break the gRPC handshake, so the pin is what makes the co-ordination
   possible rather than incidental.
2. **Image-tag bump flow** — **manual `helm upgrade` is fine for v1.** ArgoCD is a
   separate open decision ([INVESTIGATE-service-argocd-dct-deploy](../backlog/INVESTIGATE-service-argocd-dct-deploy.md))
   and coupling them would block Dagster on it. Revisit when ArgoCD is
   operationally normal.
3. **Concurrency ceiling** — **4 simultaneous run pods.** Conservative on purpose:
   it protects the shared Postgres that PostgREST, Atlas and Dagster's own
   metadata all sit on, and it fits a laptop. Set in chart values
   (`run_coordinator` / `max_concurrent_runs`), not in tenant code, so raising it
   is a platform change. Raise on evidence once real materialisations show
   numbers.
4. **GHCR pull auth** — **the pattern already exists.** `ghcr-credentials` is in
   `00-master-secrets.yml.template`; wire it as `imagePullSecrets` in the
   `dagster` namespace from day 1, even while the image is public. Adding it
   during an incident is the wrong time.
5. **Second-tenant shape** — **code-location name = the consuming application's
   name.** `atlas-data` stays as-is (it is shipped and declared in
   `[tool.dagster]`); the convention for tenant #2 is its own app name, and the
   entry lives in the same `deployments[]` list. If a tenant needs a namespace of
   its own, that is a different plan, not a bigger values file.

---

## Phase 1: The service, following adding-a-service.md

### Tasks

- [ ] 1.1 **Step 2** — `provision-host/uis/services/analytics/service-dagster.sh`:
      `SCRIPT_ID="dagster"`, `SCRIPT_CATEGORY="ANALYTICS"`,
      `SCRIPT_NAMESPACE="dagster"`, `SCRIPT_PRIORITY="56"`,
      `SCRIPT_REQUIRES="postgresql"`, `SCRIPT_PLAYBOOK="360-setup-dagster.yml"`,
      `SCRIPT_REMOVE_PLAYBOOK="360-remove-dagster.yml"`, `SCRIPT_CHECK_COMMAND`,
      website metadata, `SCRIPT_LOGO="dagster-logo.svg"`
- [ ] 1.2 **Step 3** — `manifests/360-dagster-config.yaml`, **Helm values**
      (the `-config` suffix is correct here — this genuinely is a values file)
- [ ] 1.3 **Step 4** — `manifests/360-dagster-ingressroute.yaml`, internal only
- [ ] 1.4 **Step 5/6** — `ansible/playbooks/360-setup-dagster.yml` and
      `360-remove-dagster.yml`, following `rules/provisioning.md`: `_target`,
      two-stage readiness, retry-based progress, never test `.localhost` from
      Ansible
- [ ] 1.5 ⚠️ **Pin the chart**: `--version {{ dagster_chart_version }}`, resolved
      to a concrete `1.13.x` at build time. Do not ship this unpinned
- [ ] 1.6 **Step 7 — secrets**: the metadata DB password via `urbalurba-secrets`
      in namespace `dagster`, value defined once in
      `00-common-values.env.template`. Wire `ghcr-credentials` as an
      `imagePullSecret`
- [ ] 1.7 **Step 8** — add the `dagster` Helm repo to `05-install-helm-repos.yml`
- [ ] 1.8 **Step 9** — commented-out entry in `enabled-services.conf.default`
- [ ] 1.9 **Step 10** — `stacks.sh`: **no change.** Dagster is not part of an
      existing stack and this plan does not create one

### Validation

```bash
./uis deploy dagster
./uis status                 # Healthy
./uis undeploy dagster
```

Zero-config on Rancher Desktop.

---

## Phase 2: The metadata database

### Tasks

- [ ] 2.1 Create the `dagster` database and role on the shared PostgreSQL —
      **separate from any tenant's database.** Dagster's run history is platform
      state with its own lifecycle, backup expectation and owner
- [ ] 2.2 Chart wiring: `postgresql.enabled: false` plus an existing-secret
      reference
- [ ] 2.3 Confirm the database survives `undeploy` — or state clearly that it does
      not. Run history disappearing on a redeploy would be a nasty surprise, and
      `--purge` semantics exist elsewhere in UIS for exactly this

### Validation

Dagster starts against the shared PG; the tenant's own database is untouched.

---

## Phase 3: Verify playbook — registered in every place

**Not** ending at "the Deployment is ready". A Dagster install whose daemon is
dead still shows Running pods and silently runs no schedules — which is precisely
the gap Atlas is trying to close.

### Tasks

- [ ] 3.1 `ansible/playbooks/360-test-dagster.yml` asserting:
      - the **webserver** answers (`/server_info` or the GraphQL endpoint)
      - the **daemon** is alive and its heartbeat is fresh — the load-bearing part
      - the metadata database is reachable and Dagster has migrated its schema
      - a declared **code location loads** (once one exists)
- [ ] 3.2 Register in `VERIFY_SERVICES` (`integration-testing.sh`)
- [ ] 3.3 Add the `dagster)` case to `cmd_verify()` **and** the main command case
- [ ] 3.4 Add the line to the hardcoded usage list inside `cmd_verify()`
- [ ] 3.5 ⚠️ **Do not use `kubectl run --rm -i` with an `until:` on stdout** — see
      [PLAN-docs-provisioning-unsafe-test-idiom](../backlog/PLAN-docs-provisioning-unsafe-test-idiom.md).
      A worked safe example is `088-test-postgrest.yml`

### Validation

`uis verify` lists dagster; both invocation forms run; `test-all` includes it.

---

## Phase 4: The tenant contract, and docs

This is the reusable half. Without it Dagster is an Atlas appliance with a UIS
label.

### Tasks

- [ ] 4.1 Document **how a tenant registers a code location** — the
      `dagster-user-deployments.deployments[]` entry, the gRPC entrypoint, port
      4000, the `envSecrets` hand-off. This is the service's public interface
- [ ] 4.2 Document the **language-agnostic property** — `dagster-pipes` is why a
      tenant can bring TypeScript, and why this is a platform service rather than
      a Python tool. Atlas's 40 Pipes-enabled TypeScript sources are the proof
- [ ] 4.3 State the **image-size reality**: a polyglot code-location image runs
      1.5–2 GiB and first pull on a cold node takes minutes
- [ ] 4.4 **Step 11** — `website/docs/services/analytics/dagster.md`, added to
      `sidebars.ts`; logo; build the docs in the Node container and **read the
      warnings, not the exit code**
- [ ] 4.5 Document the **Temporal-vs-Dagster** choice on the service page, so a
      user picking an orchestrator meets the distinction rather than guessing

### Validation

Someone who is not Atlas can register a code location from the docs alone.

---

## Acceptance Criteria

- [ ] Terje has approved name, category, chart version and sizing **before** Phase 1
- [ ] `uis deploy dagster` works on Rancher Desktop with no secret setup
- [ ] The chart version is pinned; no `:latest` anywhere
- [ ] Webserver **and daemon** verified alive, not merely Running
- [ ] Verify registered in all four places and reachable from `test-all`
- [ ] The metadata DB is separate from every tenant database
- [ ] Concurrency cap is set in platform values, not tenant code
- [ ] A second tenant could register from the docs without touching this plan
- [ ] Nothing on the reference installation changed as a side effect

---

## Implementation Notes

**Category: `ANALYTICS`, not `INTEGRATION`.** Temporal sits in `INTEGRATION`
alongside RabbitMQ and Gravitee — messaging and API plumbing. Dagster belongs with
`spark`, `jupyterhub`, `unity-catalog` and `openmetadata`: the data platform.
Filing them in different categories is not cosmetic — it is the clearest available
statement that they are different tools, and it prevents a future reader treating
the pair as redundant.

**Numbering.** `360` is free in both the manifest and playbook ranges. Note the
existing ANALYTICS numbering is already inconsistent — `330-setup-spark.yml`
against `300-spark-config.yaml`, `350-setup-jupyterhub.yml` against
`310-jupyterhub-config.yaml`. Do not copy that; keep manifest and playbook on
`360` per `architecture/manifests.md`.

**Testing this on the iMac will be slow.** A 1.5–2 GiB code-location image on a
2011 i5 with a cold cache is minutes of pull before anything happens, and Helm
`--wait` timeouts should be set with that in mind. Backstage's 600 s timeout was
blamed for a failure it did not cause; do not repeat the pattern in reverse by
setting one too tight.

**Atlas is not blocked by this plan and should not be treated as if it were.**
Requirement §7 lists four production-path items — schemas, PostgREST config,
`api-atlas.helpers.no` ingress, credentials — that are independent of Dagster.
Two of them are UIS-side. Dagster converts fresh-once data into continuously
fresh data; it is not on the critical path to Atlas serving anything.

---

## Files to Modify

**Service**
- `provision-host/uis/services/analytics/service-dagster.sh` (new)
- `manifests/360-dagster-config.yaml`, `360-dagster-ingressroute.yaml` (new)
- `ansible/playbooks/360-setup-dagster.yml`, `360-remove-dagster.yml` (new)
- `ansible/playbooks/05-install-helm-repos.yml` — the `dagster` repo
- `provision-host/uis/templates/secrets-templates/00-common-values.env.template`
  and `00-master-secrets.yml.template` — metadata DB password, `dagster` namespace
- `provision-host/uis/templates/uis.extend/enabled-services.conf.default`

**Verify**
- `ansible/playbooks/360-test-dagster.yml` (new)
- `provision-host/uis/lib/integration-testing.sh` — `VERIFY_SERVICES`
- `provision-host/uis/manage/uis-cli.sh` — both dispatch forms **and** the usage list

**Docs**
- `website/docs/services/analytics/dagster.md` (new), `website/sidebars.ts`
- `website/static/img/services/dagster-logo.svg` (+ `src/` variant)
