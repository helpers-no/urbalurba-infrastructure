# INVESTIGATE backlog — priority view

**Purpose**: triage tool, not a roadmap. Decides *what to investigate next* — not *what to build next*. The 38 INVESTIGATE files in `backlog/` were written at different times for different reasons; this doc separates the ones ready to be done from the ones that should wait, and orders the ready ones by what they unblock.

**Last updated**: 2026-08-30 (tenth refresh). Re-rank whenever an INVESTIGATE moves to `completed/`, a child PLAN ships, or a new INVESTIGATE lands.

**How to read the tiers**: tier order is the order to *start* the investigation, not the order to *finish*. Tier 1 means "next on deck"; Tier 4 means "don't open this yet — wait for prereqs or product clarity." Tier 0 is "in flight — no fresh investigation work needed but the file still lives here because work isn't fully shipped."

**UIS lifecycle convention**: an INVESTIGATE moves from `backlog/` to `completed/` once every child PLAN has shipped (or the investigation is otherwise closed). Once moved, it disappears from this doc — see [`completed/`](../completed/index.md) for the historical list.

---

## Current status — tor-agent, 2026-08-30 (end of day)

**`state: idle`.** Nothing is in flight, nothing is blocked, and `active/` is empty — this time
because the work genuinely finished, not because it was being tracked somewhere else.

### Two workstreams closed today

**1. The external-services proxy** — six defects across three rounds, all merged. The proxy now takes
over the Service it stands in for, the verify proves which topology answered rather than reading it
from the config file, and the round trip returns cleanly. Recorded in
[PLAN-system-external-services-proxy-takeover](../completed/PLAN-system-external-services-proxy-takeover.md).

**2. The Node 20 runtime bump** — 19 pins across four workflows, graded **8/8**. Recorded in
[PLAN-system-actions-v5-runtime-bump](../completed/PLAN-system-actions-v5-runtime-bump.md). It also
produced the 1.6.5 release, because the bump republished the container with a moved digest and an
unchanged `version.txt`, which `./uis pull` could not see.

### Three investigations filed, none started

Each was a *class* found underneath a specific fix, filed rather than patched away:

| | What |
|---|---|
| [workflow paths-filter drift](INVESTIGATE-system-workflow-paths-filter-drift.md) | Four instances of a `paths:` filter narrower than what the job depends on. Three found by the tester, the fourth by an audit that took under a second. The failure is **silence** — nothing goes red, work simply is not done |
| [launcher/image version drift](INVESTIGATE-system-launcher-image-version-drift.md) | Now carries a live instance: an image republished with a moved digest and an unchanged version, invisible to the update mechanism. Adds the open question of whether the version bump should be automatic |
| [deploy revert exit code](INVESTIGATE-cli-deploy-revert-exit-code.md) | `uis deploy` reports one exit code for two separable outcomes; the same revert gave exit 0 and exit 3 minutes apart |

### Next, in order — the ordering is mine

1. **Vulnerability scanning for the 46 running images.** The last requirement in the original queue
   that has not been started. The *code* half is already tracked at a documented floor, so only the
   pods half is open.
2. **A CI guard for the disclosure boundary** — a publicly routable address or a credential-shaped
   string should fail the build. Today that boundary is held by review alone, and Terje's decision to
   accept the existing internal addresses rests on it.
3. **The decidable half of the paths-filter class** — every workflow must list its own file. Cheap,
   mechanically checkable, and the tester independently proposed the same property.

⚠️ **Standing, and unchanged by any of today**: production runs the external-services proxy shape and
**nothing on it has been exercised** by this work. Every defect was found and proved on a single
laptop fixture, rebuilt three times by one tester. That is the gap the topology-coverage requirement
was written about, and it has been narrowed, not closed.

---

## What changed in this refresh (2026-05-07 → 2026-08-11)

The doc had gone three months without a re-rank, against a rule that says re-rank
whenever a plan ships. In that window 12 investigations landed and roughly 9 plans
shipped, so the triage view had drifted badly from the repo:

- **12 investigations were missing entirely**, including the two driving all
  current work — `system-observability` and `service-uptime-kuma`. The doc claimed
  25 files; there were 35.
- **One row pointed at a file that had already shipped**: `cli-undeploy-purge-flag`
  now lives in `completed/`. Row deleted per rule 4.
- **`system-verification-playbooks-usage` is promoted from Tier 2 to Tier 1.** It
  predicted, in March, the exact defect found on 2026-08-11: a verify playbook
  present in the repo and wired into nothing. See its Tier 1 entry.
- **Tier 0 grew from 3 rows to 7** — it was hiding how much is genuinely in flight.

---

## What changed 2026-08-13

- **Observability landed on `main` but is not finished** — 55 tasks done, 56 open.
  See its Tier 0 row. The gate defect (OBS-F6) is closed and verified against the
  shipped image; the automation the platform promises is not.
- **Tier 1 #2 gained a third and much more serious finding.** `kubectl run --rm -i`
  can return `rc=0` with empty stdout. Any verify playbook asserting on stdout can
  therefore report a passing service as failing — silently, and load-dependently.
  This idiom is used well beyond the playbook where it was found.
- **The docs site can now be built locally after all**, which changes a standing
  assumption. There is no Node on the workstation or in the provision-host
  container, so [adding-a-service](../../../contributors/guides/adding-a-service.md)
  step 11 (`npm run build`) had been skipped every time it was asked for. It runs
  fine in a container:

  ```bash
  cd website && docker run --rm -u $(id -u):$(id -g) \
    -v "$PWD":/w -w /w -e HOME=/tmp -e CI=true node:20 \
    sh -c 'npm ci && npm run build'
  ```

  The guide should say this. A required step that cannot be run on the machines
  people actually use will keep being skipped, and it was.
- **Website vulnerabilities went 99 → 2** (26 Dependabot PRs, then npm `overrides`
  for two transitive roots Dependabot cannot reach). The remaining two are
  `image-size` with no published patch — a floor, not a backlog item.
- The first local build surfaced **pre-existing broken links and one broken
  anchor** in the docs. Warnings, not failures. Currently owned by nobody.

---

## What changed 2026-08-30 (tor-agent, UIS maintainer)

- **The broken-link item above is CLOSED.** It was the last bullet of the 2026-08-13
  refresh and had been nobody's for a fortnight. `onBrokenLinks`, `onBrokenAnchors` and
  `onBrokenMarkdownLinks` are now `'throw'`, the one broken anchor is fixed, and the
  build runs on pull requests — so a broken link fails the PR rather than reding `main`.
  Graded PASS by the independent tester in two rounds (`9e79334`, `4ebee23`).
- **The container-build recipe above is no longer the only option.** That bullet says
  there is no Node on the workstation or in the provision-host container. There is Node
  on the maintainer machine now, and `cd website && npm run build` runs natively in about
  31 s warm. The container recipe still works and is still right for machines without
  Node; it is no longer the only route, and the pre-flight is documented in
  [documentation.md](../../../contributors/rules/documentation.md).
- **A stray `1priority.md` existed for two hours and has been deleted.** ops's first
  status poll asked every agent to create `plans/backlog/1priority.md`; that was ops's
  error, and on a case-insensitive filesystem the lowercase twin would have silently
  overwritten *this* file. I wrote to `plans/1priority.md` instead so nothing was lost,
  and the revised poll confirmed there is no new file. Its content is folded into the
  status section at the top of this document, and the stray is removed.
---

## What changed 2026-08-26 (sixth entry) — topology coverage gets a file

- **[system-topology-coverage](INVESTIGATE-system-topology-coverage.md) filed.** A
  requirement from ops (25/8, at Terje's direction) that had been accepted and
  "queued" for a day while existing only as a message in `terchris/home`. It had a
  queue position and no artefact — the same shape as the defects it is about, where
  an absent record reads as a live one. Outcomes 1 and 4 (target_host plumbing,
  loud configuration errors) already shipped via `lib/verify-target.sh`; **outcome 2
  is open — nothing yet exercises the external-postgres proxy topology.**
- **Version system shipped** (1.5.2 → 1.6.3): one `version.txt`, remote-version
  detection on every command, display in `help`/`status` and on the website navbar,
  launcher self-update, and untagged-image cleanup. Verified by ops on asgard.
  UIS stays on **1.6.x until every service runs on asgard** — Terje, 25/8.
- **TALK protocol v2 adopted.** Messages now live in `ai-developer/talk/` in
  `terchris/home` and **rounds append under `## Round N` rather than overwriting**.

---

## What changed 2026-08-23 (fifth entry) — browserless shipped, Dagster shipped

Both were built through the new **build/verify-separated** loop: assist builds,
the imac tester verifies independently on a prod-matched cluster. Two very
different results, and the difference is the point.

- **[browserless-001](../completed/PLAN-service-browserless-001-deploy.md) shipped
  — PASS on all four criteria, first attempt, zero defects returned.** The
  `AUTOMATION` category is live; browserless is the first service in it. This is
  the fix for the gap noted in the 2026-08-21 (second entry) below: Uptime Kuma's
  `real-browser` monitor type was dead in every installation because no Chrome
  existed to connect to. It now has one.
- **[dagster-001](../completed/PLAN-service-dagster-001-deploy.md) shipped — but
  took three rounds and six defects.** Row 27 in Tier 4 is updated accordingly.
- **The difference between one round and three was where the bugs were found.**
  browserless had two defects of exactly the same class as Dagster's — but both
  were caught by the builder's own smoke checks *before* handover, because the
  build ran a real render rather than reading a health endpoint. Dagster's D2, D3
  and D5 all reached the tester because the verify checked *whether a command
  succeeded* rather than *whether the system reached the right state*.
- **Concretely**: browserless spent part of its build `1/1 Running`, zero
  restarts, with `/pressure` reporting `"isAvailable": true` — and every render
  failing. A volume mount had shadowed the browser's data directory. No health
  signal moved. Its verify therefore renders a page and asserts a marker comes
  back, and **that assertion was tested against the bug** before handover:
  reintroducing the mount makes it fail while the pod stays healthy.
- **This is the third independent confirmation for Tier 1 #2**
  ([verification-playbooks-usage](INVESTIGATE-system-verification-playbooks-usage.md)),
  now arriving from a service that had no verify playbook at all until this week.
  The investigation predicted "deployments report success when no real validation
  happened"; a green `/pressure` on a browser that cannot render is precisely that.
- **New: [uis-docs-writes-outside-repo](PLAN-cli-uis-docs-writes-outside-repo.md).**
  `./uis docs` run from a workstation checkout writes to `/mnt/urbalurbadisk/…`,
  prints `✓ Generated … (34 services)` and exits 0 while leaving the repo
  untouched — so a newly added service silently never reaches `services.json`.
  Found the hard way here. Same family as Tier 1 #2 and the `test-all` gap: a
  command reporting on its own execution rather than on the state it produced.
- **Still open**: neko-001 is next and depends on the AUTOMATION category this
  created.

---

## What changed 2026-08-21 (fourth entry) — validation run, three fixes, three plans

Eighteen services validated on a factory-reset Rancher Desktop. Four bugs found
and three fixed the same day; see
[STATUS-rancher-desktop-validation-2026-08-21](../completed/STATUS-rancher-desktop-validation-2026-08-21.md).

- **Fixed and pushed**: the Backstage catalog generator emitting invalid
  ConfigMap keys from a trailing comment (`3aa3ef2`); Backstage resolving a
  floating third-party plugin index, plus its chart pinned (`c7dae01`); and a
  deploy following an undeploy dying on the terminating namespace (`91fd276`).
- **New: [helm-chart-version-pinning](PLAN-system-helm-chart-version-pinning.md).**
  Terje's call after Backstage broke on a floating dependency. **Measured: 16 of
  24 Helm-based services have no `--version`** — two thirds of the observability
  stack among them. Backstage was the worst shape of all: image pinned, chart
  floating, so the pairing that ran was never the pairing that was tested. Phase
  3 records the wider lesson — *a pinned chart is not a pinned deploy*, since
  Backstage's actual failure was an artefact the chart fetched at install time.
- **New: [test-all-coverage-and-dry-run](PLAN-cli-test-all-coverage-and-dry-run.md).**
  `--dry-run` omits the clean phase, so it shows the constructive half of the plan
  and hides the destructive half. Plus `gravitee` skipped permanently with no
  date or issue, and `SKIP_SERVICES_CONDITIONAL` empty.
- **The recurring shape, now three-for-three**: the failure names the wrong
  service. OBS-F6 blamed Grafana; the namespace race blamed enonic; Backstage
  went through two wrong causes. Each cost a wrong theory first, because the
  obvious next step — investigate the service named — is always wrong.
- **Counter-evidence for `test-all`**: it *found* the namespace race, which
  nothing else would have. An argument for running it more, and therefore for it
  being honest about what it skips.

---

## What changed 2026-08-21 (third entry) — approvals, sequencing, and two bugs filed

- **Terje approved** the two-service split, the `AUTOMATION` category, and
  **neko as a planned service — with browserless shipping first**. Both plans
  updated from "awaiting approval" to approved-and-sequenced.
- **Both plans were rewritten from scratch** after Terje asked whether I had read
  `adding-a-service.md` and the rules docs. I had not, well enough — they were
  written from reading service definitions and inferring the rest. They missed
  the category registry (`categories.sh`), `enabled-services.conf`, `stacks.sh`
  and `sidebars.ts`; used `-config.yaml` for manifests that are not Helm values;
  numbered an IngressRoute against the wrong playbook; and did not know
  `SCRIPT_PLAYBOOK`/`SCRIPT_MANIFEST` are mutually exclusive. Recorded in the
  browserless plan's Implementation Notes rather than quietly fixed, because
  "wrote a plan from inference and it looked complete" is the failure worth
  remembering.
- **New: [provisioning-unsafe-test-idiom](PLAN-docs-provisioning-unsafe-test-idiom.md).**
  `rules/provisioning.md` presents the `kubectl run --rm -i` + `until:` on stdout
  idiom as the CORRECT pattern, in two sections. That is Tier 1 #2's third
  finding, and this is its **propagation source** — it explains why the idiom
  "appears across other services' verify playbooks." Recorded on the
  investigation too; the plan fixes the source and hands the occurrence list back
  rather than sweeping services itself.
- **[verify-registration-fix](PLAN-cli-verify-registration-fix.md) gained task
  2.4** — a *fourth* hand-maintained list, the usage text inside `cmd_verify()`.
  Currently in sync, so drift-prevention rather than a live defect; better derived
  from `VERIFY_SERVICES` than documented as a fourth place to edit.
- **A process note worth keeping**: I cited `PLAN-cli-verify-registration-fix` by
  filename in two plans without opening it, then reported its contents back as a
  discovery. Search found the file; I did not read it. Citing is not reading.

---

## What changed 2026-08-21 (second entry) — the browser platform becomes a service

- **Terje decided the browser platform ships as a UIS service.** Not reopened.
  What was open — name, category, scope — is proposed in two plans **awaiting his
  approval**: [browserless-001](../completed/PLAN-service-browserless-001-deploy.md) and
  [neko-001](PLAN-service-neko-001-optional-addon.md). Nothing is self-approved.
- **Filed as two plans on purpose**, so scope can be approved by approving one
  and not the other. browserless and neko have different second-user cases and
  materially different blast radii; bundling them would hide that.
- **browserless passes the second-user test on a fact, not a hope.** UIS already
  ships Uptime Kuma; its `real-browser` monitor type calls
  `chromium.connect(remoteBrowser.url)` and the image UIS deploys has no Chrome —
  so that monitor type is **dead in every installation today**. browserless is
  the missing piece, and serves the exact Playwright websocket route Uptime Kuma
  connects to. Both facts verified in upstream source.
- **A related gap this surfaced**: UIS's "E2E tests" are all API-level. Nothing
  can currently assert that a *page renders*, for any of the ten-plus services
  UIS ships with a web UI. OBS-F6 — the flaky Grafana E2E — is a test asserting
  on API responses because asserting on the rendered dashboard was impossible.
- **neko is argued both ways in its plan and gated hard.** It fails the purpose
  test in the environment UIS calls baseline: on Rancher Desktop the human is
  already where the cluster is, with a logged-in browser open. Recommended
  shipped-but-never-default, because the Case-2 auth problem is real and UIS has
  no other answer — but nothing establishes a second installation wants it.
- **Proposes a new `AUTOMATION` category** (manifests 400–429, 430–499 reserved).
  `OBSERVABILITY` was tempting and is wrong: browserless is a capability
  observability *consumes*, not an observability tool.

---

## What changed 2026-08-21

- **New investigation landed and closed the same day: [roaming-dependency-addresses](INVESTIGATE-system-roaming-dependency-addresses.md)** — not ranked, nothing to investigate next.
  Arrived as a productisation request from ops for a running `ollama-endpoint-manager`,
  and was answered rather than deferred: LiteLLM **partly** covers it. Ordered
  address preference (`order`) and health-check-driven routing are native; the
  fail-fast property is not, and upstream has explicitly chosen the opposite
  (`"All deployments marked unhealthy by health checks, bypassing health filter"`
  in `router.py`). Verdict: not an AI/ML component — it belongs to the dependency
  layer, as an optional rendering of
  [dependencies-shim-services](PLAN-system-dependencies-shim-services.md) Phase 1.
- **Decided the same day (Terje): the reconciler is installation implementation,
  not UIS.** No service, no name, no dependency-layer rendering. A UIS feature
  needs a second plausible user, not just a generalisable mechanism, and two
  roaming sleeping Macs is a single-installation topology — the boundary both
  repos already state. Reproducing it is ops' work, in the home repo.
  **The challenge this raised against
  [dependencies-shim-services](PLAN-system-dependencies-shim-services.md) is
  withdrawn**; that plan is unaffected and the candidate-list-vs-discovery
  distinction is parked in its notes rather than left open.
- **What survives is entirely about LiteLLM, not about the reconciler**: the
  parity findings, and one unwritten child — a LiteLLM recipe (two deployments,
  one `model_name`, `order: 1`/`order: 2`, `enable_health_check_routing`, with an
  honest account of the probe cost and the fail-fast caveat). That is general and
  has obvious second users. **It is the only live thread left in that file**, and
  the reason it sits in `backlog/` rather than `completed/`.
- **Evidence that static `Endpoints` drift is not hypothetical.** Both Ollama
  addresses committed in `hosts/asgard/ollama-backends.yaml` are stale; read live
  on asgard the same day, both hosts had moved and neither committed address was
  in use. The reference installation only kept working because an unproductised
  reconciler was absorbing it.
- **[version-pinning](INVESTIGATE-system-version-pinning.md) (Tier 2 #9) gained a
  concrete consumer.** The LiteLLM chart is unpinned, and `order` — the mechanism
  the recipe half of the verdict depends on — was broken in v1.80.11
  (BerriAI/litellm#18444) and silently degrades to round-robin across a dead
  address when it regresses.

---

## Tier 0 — in flight

INVESTIGATEs that still live in `backlog/` because their work isn't fully shipped yet — either active on a feature branch, or investigation-complete and waiting for a child PLAN to be drafted. No fresh investigation work needed; listed here so the priority view surfaces what's already moving. Items whose child PLANs have all shipped are not listed — they're in [`completed/`](../completed/index.md).

| Investigation | Child plans | State |
|---|---|---|
| [system-observability](INVESTIGATE-system-observability.md) | 6 in `backlog/` (001 log-collection, 002 alert-baseline, 003 service-dashboards, 004 external-targets, 006 service-probes, grafana-deploy-gate-fix) | **The largest thing in flight — and now merged, but not finished.** 55 tasks done / 56 open. Everything through 2026-08-13 is on `main`: OBS-F6 is closed and verified against the *shipped container image*, not a patched one. What remains is what the platform's own requirement turns on — **003's dashboards are still applied by hand, so a rebuild from nothing does not produce them**. Also open: Loki retention undecided (001), cert expiry (002), external-targets phases 2–4, grafana Phase 4 (move E2E to a verify playbook), and 006 at 0/27. **Do not open 006 before the artifact convention is decided** — 003 and 006 must share one, and deciding it unblocks both plus Tier 3 #17. |
| [service-uptime-kuma](INVESTIGATE-service-uptime-kuma.md) | 2 in `active/`, 2 in `backlog/`, 1 shipped | Deployed on **assist** with 19 monitors reconciling. Its own 002 plan records the gap that matters: **nothing notifies** — no job calls the push URLs. Do not close this investigation until that is either done or split out. |
| [service-litellm-install-reliability](INVESTIGATE-service-litellm-install-reliability.md) | 3 in `backlog/` (002 version-pinning, 003 undeploy-purge, 004 config-portability), 1 shipped | 001 schema-verify shipped; the remaining three are drafted and unstarted. |
| [system-platform-provisioning-layer](INVESTIGATE-system-platform-provisioning-layer.md) | 1 in `backlog/` (aks-001b manual-setup), 2 shipped | Status ACTIVE, AKS-focused. Step 1 verified end-to-end 2026-05-11 against a real Azure subscription; `platforms/azure-aks/` is the production path. Next concrete work: Step 2 (start/stop/scale so the cluster doesn't bill 24/7). |
| [cli-stack-profiles](INVESTIGATE-cli-stack-profiles.md) | 1 in `backlog/` (grafana-optional-datasources) | The child plan is blocking: no `--profile` below `full` can install until it ships, and `uis stack install observability --skip-optional` is broken today (CLI-F1). |
| [service-authentik-user-config](INVESTIGATE-service-authentik-user-config.md) | none drafted | Investigation Complete — Ready for PLAN. Unblocks Tier 3 backstage-auth. |
| [system-remote-deployment-targets](INVESTIGATE-system-remote-deployment-targets.md) | none drafted | Investigation Complete. Child PLAN drafting next; do not open as new investigation work. |

## Tier 1 — do next (load-bearing or unblocks active work)

| # | Investigation | Effort | Why this tier |
|---|---|---|---|
| **NEW** | [system-topology-coverage](INVESTIGATE-system-topology-coverage.md) | M | **Filed 2026-08-26 from an ops requirement.** Three defects in one morning, all the same class: an assumption true only of the development topology. The tester and production differ on exactly two axes — context name and postgres shape — and all three defects lived there. Ranked Tier 1 because it is the systemic version of a failure that has already cost four hand-found production defects, and because part of the answer is cheap: a **lint**, not a second cluster. Outcomes 1 and 4 shipped; **outcome 2 (exercise the proxy topology) is open**. ⚠️ Do not "fix" this by switching the tester to production's shape — in-cluster postgres is a supported configuration and swapping moves the blind spot. |
| 1 | [secrets-template-defaults-clarity](INVESTIGATE-secrets-template-defaults-clarity.md) | S | Foundational fix to the secrets workflow every service depends on. The current silent-overwrite confusion between `00-common-values.env.template` and `default-secrets.env` produces bug reports from contributors and slows every onboarding. Investigation already half-shipped via the existing template scaffolding; closing it out is a small read-and-decide. |
| 2 | [verification-playbooks-usage](INVESTIGATE-system-verification-playbooks-usage.md) | M | **Promoted from Tier 2 on evidence, and the evidence keeps arriving.** Written 2026-03-12, it states the risk as "verification playbooks present but not wired into active setup or test flows → deployments report success when no real validation happened." Three separate confirmations since: (1) `031-test-alloy.yml` was reachable by no command at all while its docs page told users to run it; (2) uptime-kuma's verify was invisible to `test-all`; (3) **`kubectl run --rm -i` silently returns rc=0 with empty stdout** when the container outlives the attach — every `until:` asserting on stdout then reads a successful call as a failure. (3) is the serious one: the same idiom appears across other services' verify playbooks, so an unknown number of them can fail or pass for reasons unrelated to the service. All three are fixed ad-hoc; this investigation is the systematic version. **Stays Tier 1, not Tier 0, on purpose** — its child plans are point fixes to the services that happened to break, not the investigation's output. |
| 3 | [external-or-in-cluster-services](INVESTIGATE-system-external-or-in-cluster-services.md) | M | **New 2026-08-13.** OpenBao, the registry cache and the backup chain run on Odin, built by hand, with no service definition — the exact state Alloy was in before it was made a real service. Rebuild Odin and they are rebuilt from memory; OpenBao holds the vault recovery keys. The requirement is that they also run on Rancher Desktop, which needs one convention: how a service is *provided externally* in one installation and *deployed in-cluster* in another, behind one interface. `.uis.extend/` is the half-built precedent (shipped twice, for watching external things, never for substituting them), and six database services already live this shape undeclared. A full `pct list` of Odin found **six** components, not three: `pg` and `minio` already have both a service definition *and* a hand-built proxy (unproductised, not missing), `bao` and the `registry` mirrors have nothing, and **`nas` (Samba/NFS) is parked pending a scope decision** — the laptop answer is probably Rancher Desktop's existing storage class rather than shipping Samba, but that should be decided deliberately. `ops` is not a service: it is the host running `uis-provision-host` itself. **First child plan SHIPPED 2026-08-14** — PostgreSQL and MinIO both run from the convention, and the reference installation has zero hand-written proxies left. Remaining children: `bao`, the `registry` mirrors, cluster backup. **Decide alongside the observability artifact convention** — same question in a different costume, and two answers would never converge. |
| 4 | [service-openbao](INVESTIGATE-service-openbao.md) | M | **New 2026-08-14.** OpenBao holds the vault recovery keys and is the only Odin component with neither a service definition nor an investigation — built entirely by hand, so a rebuild reconstructs it from memory. Written expecting it to reuse the proxy convention; **measuring showed the convention does not fit.** OpenBao speaks TLS with a private CA whose SANs cover no in-cluster name (BAO-F2); its `kubernetes` auth runs *into* the cluster via TokenReview, a direction a proxy cannot help with (BAO-F3); and nothing talks to it except ESO — apps read ordinary Secrets — so the interface needing parity is the `ClusterSecretStore` **name**, not an address (BAO-F1). That makes dev cheaper than expected: run it in-cluster under the same store name and every `ExternalSecret` works unchanged. |
| 5 | [secrets-dev-to-production](INVESTIGATE-secrets-dev-to-production.md) | S–M | **New 2026-08-14.** Follows one secret from a developer's laptop into production. The application side is already portable — the manifest is identical — but the machinery meant to notice a missing or fake value is not. `envsubst` renders an unset key as an **empty string, silently** (verified); validation is a **hardcoded allowlist** of 7 required and 6 weak-value names against a 62-key template, so a newly added secret is checked for neither; and `validate_secrets` is **not on the `uis deploy` path** at all. Net effect: `LocalDevStripe123` can reach production without a single warning. Same allowlist-that-new-things-never-join shape as the verify-registration defect. **Do this before the vault question** — none of these failure modes is fixed by having a vault. |
| 6 | [uis-deploy-no-playbook-semantics](INVESTIGATE-cli-deploy-no-playbook-semantics.md) | S | Genuine ambiguity in the deploy code today: services with `SCRIPT_PLAYBOOK=""` produce undefined behaviour. Affects every "metadata-only" service. Investigation gap is small; pinning the contract removes a class of latent bugs across all current and future services. |
| 7 | [uis-deploy-auto-regen-secrets](INVESTIGATE-cli-deploy-auto-regen-secrets.md) | M | UX gap that bites tester loops repeatedly: stale `kubernetes-secrets.yml` produces silent failures. Decisions here lock down idempotency for the whole deploy command. Tester-feedback-driven; high payoff per hour. |

## Tier 2 — do after Tier 1 (independent, ready, valuable)

| # | Investigation | Effort | Why this tier |
|---|---|---|---|
| 8 | [in-cluster-port-on-services](INVESTIGATE-docs-services-in-cluster-port.md) | S | Small `services.json` schema addition that downstream consumers (Backstage catalog, docs generator, future MCP integrations) keep working around. Cheap to land; immediate downstream payoff. |
| 9 | [version-pinning](INVESTIGATE-system-version-pinning.md) | M | Cross-cutting consistency review: which services have pinned image tags vs `:latest`. Affects supply-chain hygiene and CI reproducibility. Independent of other tiers; ships value on its own. |
| 10 | [service-version-metadata](INVESTIGATE-system-service-version-metadata.md) | M | Tied to docs/CLI display: how service scripts expose version info. Closes a presentation gap visible on every service page. Pairs naturally with #6 if done together. |
| 11 | [system-backup-and-scheduling](INVESTIGATE-system-backup-and-scheduling.md) | M | **Newly triaged; scope narrowed 2026-08-13.** There is **no Velero** anywhere. Odin runs five mechanisms across three layers — `vzdump`, `sanoid`, `syncoid`, `restic`, `pgBackRest` — none Kubernetes-aware and **none able to run on Rancher Desktop**. So this investigation owns the *host layer* only: documenting and making reproducible what already exists, outside UIS where it belongs. **Cluster backup** (namespaces, PVCs, secrets) is a separate, currently-uncovered gap — `vzdump` restores the whole k8s VM but not one namespace — tracked under [external-or-in-cluster-services](INVESTIGATE-system-external-or-in-cluster-services.md) EXT-F6. Original note: Backup + scheduled-job story for the platform. Load-bearing in the same way #2 is: an unverified backup and an unwired verify playbook fail identically — silently, and only when you need them. Ranks below Tier 1 only because no current work is blocked on it. |
| 12 | [system-registry-cache](INVESTIGATE-system-registry-cache.md) | M | **Newly triaged.** Pull-through image cache. Independent, self-contained, and pays off on every cluster rebuild — which the platform does often by design. |
| 13 | [uis-connect-commands](INVESTIGATE-cli-connect-add.md) | M | User-facing convenience: `uis connect <service>` opens an interactive client without requiring host-side tooling. Independent of platform/deployment tiers; shippable as a self-contained slice. |
| 14 | [cli-grammar-harmonization](INVESTIGATE-cli-grammar-harmonization.md) | M | **Newly triaged.** Consistency of the `uis <verb> <noun>` surface. Related in spirit to #2: the verify command exists in two grammatical forms (`uis verify alloy` and `uis alloy verify`), which is precisely how the registration defect stayed hidden. Worth doing before the CLI surface grows further. |
| 15 | [cli-top-level-doc](INVESTIGATE-cli-top-level-doc.md) | S | **Newly triaged.** One coherent top-level CLI reference. Small, and the 2026-08-11 help-text gaps (three services dispatching correctly but undocumented) show the current help is maintained by hand and drifts. |
| 16 | [docs-markdown-update-logic](INVESTIGATE-docs-markdown-update-logic.md) | M | Improves the docs-generation pipeline so metadata-driven sections update without overwriting manual prose. Quality-of-life for contributors maintaining service pages. |
| 17 | [cli-network-export-import](INVESTIGATE-cli-network-export-import.md) | M | **Newly triaged.** Moving network config between installs. Ready but not blocking anything; sits at the bottom of Tier 2 until a concrete consumer pulls on it. |

## Tier 3 — defer until prereqs ship

These have known prerequisites that are still open. Don't open them yet — the prereq's outcome materially changes the investigation's scope.

| # | Investigation | Waits on | Why defer |
|---|---|---|---|
| 18 | [backstage-auth](INVESTIGATE-service-backstage-auth.md) | authentik-user-config (Tier 0, ready for PLAN) | Adding Authentik OIDC to Backstage assumes Authentik's user-config story is settled. Open the auth investigation only after the user-config PLAN has shipped, otherwise the OIDC client config keeps shifting. |
| 19 | [provision-host-tools-and-auth](INVESTIGATE-system-provision-host-tools-and-auth.md) | platform-provisioning-layer (Tier 0, in flight) | Decisions about which CLIs (Azure / AWS / GCP / Terraform) live inside `uis-provision-host` depend on the platforms model that the active feature branch is still settling. Designing tool-install + auth-state before platforms lock in = rework. |
| 20 | [monitor-definitions-with-services](INVESTIGATE-system-monitor-definitions-with-services.md) | observability 003 + 006 (Tier 0) | **Newly triaged.** Shipping monitor/probe definitions alongside each service shares an artifact convention with observability's dashboards (003) and probes (006). Both are open and still deciding that convention; designing a third consumer first guarantees rework. |
| 21 | [migrate-hosts-to-platforms](INVESTIGATE-system-migrate-hosts-to-platforms.md) | platform-provisioning-layer (Tier 0, in flight) | Includes the documentation migration, folded in deliberately — the code and docs sides belong together. Waits on the same platforms model as #16. |
| 22 | [tailscale-cross-cluster-backbone](INVESTIGATE-network-tailscale-cross-cluster-backbone.md) | platform-provisioning-layer; a real second site | **Newly triaged.** Cross-cluster networking is only designable once there is a second cluster that must be reached the hard way. Related to the Oslo+Bodø multi-site intent, which is not yet built. |
| 23 | [dct-argocd-deploy](INVESTIGATE-service-argocd-dct-deploy.md) | argocd as a stable UIS service | The "deploy from inside DCT with one command" flow needs argocd to be the deployment substrate. ArgoCD has a manifest in UIS but isn't an everyday service yet; investigate this once argocd is operationally normal. |
| 24 | [enonic-deployment](INVESTIGATE-service-enonic-deployment.md) | enonic-as-stable-service | Covers both apps (JAR pipeline — chosen-approach decided) and content (still open). Pull-based deployment design assumes Enonic XP is operationally stable in UIS. Merged from the two earlier app + content investigations on 2026-05-15. |
| 25 | [email-smtp-service](INVESTIGATE-service-email-smtp.md) | product clarity (which services need email first?) | Cross-cutting platform service. Worth opening only when the first concrete consumer (Authentik password resets? a notification path?) is actually pulling on it. |

## Tier 4 — ideas, not investigations

These are sketches / parking-lot entries, not concrete research targets. Don't open them as INVESTIGATEs — let the surrounding context resolve, then either promote to a real INVESTIGATE or delete.

| # | Item | What to do |
|---|---|---|
| 26 | [espocrm](INVESTIGATE-service-espocrm.md) | Currently four URLs and zero analysis. Either promote to a real INVESTIGATE (with a goal + comparison against alternatives) or delete. |
| 27 | [dagster](INVESTIGATE-service-dagster.md) | ✅ **Trigger met 2026-08-22 — no longer deferred.** This row said to wait for "the data-orchestration use case to materialise into a real consumer". It has: Terje decided Dagster becomes a reusable UIS service, and Atlas is done and waiting — 41 sources, 40 Pipes-enabled, code-location image publishing on every commit. **Shipped 2026-08-23** as [PLAN-service-dagster-001-deploy](../completed/PLAN-service-dagster-001-deploy.md) — approved, built, and independently verified after three rounds and six defects. The investigation stays here as the design record; it is four months stale on source counts but its structural decisions held. |
| 28 | [metabase](INVESTIGATE-service-metabase.md) | Similar to #24 — internal BI / data exploration tool selection. Hold until there's a concrete first consumer driving the requirements. |
| 29 | [customer-onboarding-database](INVESTIGATE-docs-customer-onboarding-database.md) | **Newly triaged.** Self-described as "Draft / not yet scheduled." Leave as a sketch until there is a real customer-onboarding flow to design against. |

---

## Ready to move to `completed/`

Every declared child PLAN has shipped. Per rule 4 these should be `git mv`'d and
their rows deleted from this doc — listed rather than moved because moving files
is a git operation.

| Investigation | Child plan that shipped |
|---|---|
| [service-backstage-enhancements](INVESTIGATE-service-backstage-enhancements.md) | `PLAN-004-backstage-api-entities` |
| [templates-first-uis-template](INVESTIGATE-templates-first-uis-template.md) | `PLAN-002-uis-template-command` |

## Housekeeping found during this refresh

- **The parent-link key is not consistent**, so plans go missing from any triage
  that walks it. PLANS.md's template says `**Investigation**:`, but
  `PLAN-system-observability-006-service-probes` legitimately has two parents and
  writes `**Investigations**:` (plural). Two parents is a real case the template
  does not cover — the convention should name both keys rather than the plural
  form being treated as a mistake.
- **`PLAN-service-uptime-kuma-005-ship-the-pipeline` genuinely has no parent
  link** — it declares Prerequisites and Related but never its investigation.
  It is also `## Status: Active` while sitting in `backlog/`, making it the
  seventh plan claiming Active.
- **Six plans carry `## Status: Active`** while PLANS.md says 1–2 at a time, and
  four of those sit in `backlog/` rather than `active/`. The folders no longer
  describe reality — worth a pass before starting anything new.

## Cross-cutting notes

- **Two natural workstreams**: UIS-internal correctness (Tier 1) and developer-experience polish (Tier 2, items #5–#14). They can run in parallel — different files, no merge contention.
- **The verification thread**: #2 (verification-playbooks-usage), #11 (cli-grammar-harmonization) and #12 (cli-top-level-doc) are three views of one problem — the CLI surface and its test wiring are maintained by hand and drift silently. Doing #2 first gives the other two concrete evidence to work from.
- **Backstage cluster**: Backstage core (shipped) → #15 (auth) → enhancements (ready to move to `completed/`). 
- **Platform/host cluster**: Tier 0 platform-provisioning-layer (in flight) → #16 (provision-host tools) → #18 (host migration) → #19 (cross-cluster backbone). Tight chain; resolve in order.
- **Observability cluster**: Tier 0 system-observability is the bottleneck for #17 (monitor definitions) and shares an artifact convention with it. Finish 003/006 before opening #17.
- **External coupling with atlas**: atlas's deployment-pipeline investigation explicitly waits on UIS's dagster signal. Resolving #24 unblocks atlas's deployment-pipeline; deferring it keeps that block in place — fine if no UIS consumer is pulling on dagster yet, but worth flagging when atlas next asks.
- **Idea-vs-investigation ratio**: 4 of 35 are still ideas (Tier 4). Healthy — most of the backlog is concrete work, not brainstorm residue.
- **Investigation-completion debt**: 2 of the 7 Tier-0 entries (remote-deployment-targets, authentik-user-config) are "investigation complete" without a child PLAN drafted. Picking one up as the next PLAN-drafting task closes more uncertainty than starting any Tier-1 investigation.

## How to use this doc

1. Pick the top unstarted item from Tier 1; if all of Tier 1 is in flight or done, move to Tier 2.
2. When starting an INVESTIGATE, leave it in this folder and update its `Status:` line to note the work is in flight.
3. When an INVESTIGATE produces a recommendation and a child PLAN is drafted, update this doc: move the row to Tier 0 and note the PLAN it spawned.
4. When every child PLAN of an INVESTIGATE has shipped, `git mv` the file to `completed/`, fix any cross-references, and **delete** its Tier 0 row from this doc — `completed/index.md` carries it from then on.
5. When a Tier-3 prereq lands, promote its dependents up to Tier 2 in the next refresh.
6. Re-rank quarterly or after every 3 INVESTIGATEs ship — whichever comes first.

### Keeping it current

The May→August drift happened because rules 3 and 4 fire at moments when the
person is thinking about *code*, not about triage. Concrete triggers, so the
update is a step in the work rather than a separate chore:

- **A new `INVESTIGATE-*.md` lands in `backlog/`** → add its row in the same
  commit. An investigation absent from this doc is invisible to triage.
- **A PLAN moves to `completed/`** → check whether its parent investigation has
  any child plans left. If not, move it and delete its row (rule 4).
- **A PLAN is drafted** → move its parent to Tier 0 (rule 3).
- **A new PLAN is written** → give it a `**Investigation**:` header linking its
  parent, or it will not be findable from here.
- **The counts in the header** (`N INVESTIGATE files`) are checkable against
  `ls backlog/INVESTIGATE-*.md | wc -l` — if they disagree, the doc is stale.
