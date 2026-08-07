# Plan: Grafana runs with only the datasources that exist

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: Make Grafana deployable with Prometheus alone, provisioning Loki and
Tempo datasources only when those services are actually deployed — so a
metrics-only observability install is expressible at all.

**Last Updated**: 2026-08-06

---

## Dependencies

**Investigation**: [INVESTIGATE-cli-stack-profiles](./INVESTIGATE-cli-stack-profiles.md)
(CLI-F1, CLI-F2) — also answers [INVESTIGATE-system-observability](./INVESTIGATE-system-observability.md)'s **Q3**.

**Prerequisites**: none. This plan is deliberately standalone.

**Blocks**: `PLAN-cli-stack-002-profiles` — no `--profile` value below `full` can
install successfully until this ships. Also unblocks today's broken
`uis stack install observability --skip-optional` (CLI-F1).

**Priority**: High

---

## Problem Summary

`uis deploy grafana` and `uis stack install observability --skip-optional` both
fail unless the entire observability stack is present. The investigation
attributed this to one metadata line. **Tracing the actual code shows two
independent blockers, and the second is the larger one.**

### Blocker 1 — service metadata (known, CLI-F2)

`provision-host/uis/services/observability/service-grafana.sh:19`

```bash
SCRIPT_REQUIRES="prometheus loki tempo otel-collector"
```

`check_dependencies()` (`provision-host/uis/lib/service-deployment.sh:292`) hard-fails
on any missing entry, so deployment dies before the playbook runs.

### Blocker 2 — the playbook enforces the same thing again (new)

**Reducing `SCRIPT_REQUIRES` alone changes nothing.** `034-setup-grafana.yml`
task 20 (`FAIL deployment if core tests did not pass`) aborts the play unless
*all* of these pass:

| Task | Asserts | Needs |
|---|---|---|
| 10 | Prometheus datasource reachable | prometheus |
| 11 | Loki datasource reachable | **loki** |
| 12 | Tempo datasource reachable | **tempo** |
| 13 | Prometheus returns data | prometheus |
| 14–16 | push logs via OTLP → query back through Grafana | **loki + otel-collector** |
| 17–19 | push traces via OTLP → query back through Grafana | **tempo + otel-collector** |

So a metrics-only Grafana would fail later, in the playbook, with a worse message
than the dependency check gives today. Three further consequences:

1. **Datasource proxy IDs are positional.** Every check calls
   `/api/datasources/proxy/1|2|3/…`, which assumes Prometheus=1, Loki=2, Tempo=3.
   Once datasources are conditional those positions shift, and a metrics-only
   install would silently proxy the wrong datasource rather than error. The repo
   uses positional IDs in every call today and UID-based paths in none
   (`grep -c 'proxy/uid'` → 0).
2. **`otel-collector` is a hidden fourth dependency** — tasks 14, 17, 24 and 25
   push through `otel-collector-opentelemetry-collector`, independent of anything
   `SCRIPT_REQUIRES` declares.
3. **The shipped dashboards assume all three.** `035-grafana-test-dashboards.yaml`
   references `loki` (×2) and `tempo` (×2) datasource UIDs;
   `036-grafana-sovdev-metrics.yaml` references `loki` (×4). Task 23 blocks until
   ≥4 dashboard ConfigMaps exist. On a metrics-only install these panels render
   datasource errors.

The playbook's E2E tasks are also the OBS-F6 flaky race (retry-3 against Tempo's
block flush) — this plan makes them conditional, it does not fix their timing.

---

## Phase 1: Baseline — reproduce both failures

Turns CLI-F1's traced conclusion into a measured one. **Nothing is changed in
this phase**; its output is the expected-fail record for every phase below.

### Tasks

- [ ] On a clean cluster, deploy Prometheus only: `uis deploy prometheus`
- [ ] Attempt `uis deploy grafana` — record the exact `die_dependency` message
- [ ] Temporarily set `SCRIPT_REQUIRES="prometheus"` (do not commit) and retry —
      record where the playbook aborts and what task 20 prints
- [ ] Attempt `uis stack install observability --skip-optional` on a clean
      cluster — record the failure point (CLI-F1's unverified repro)
- [ ] Revert the temporary edit

### Validation

Three recorded failures, each with its message. If any of them *passes*, stop:
the finding is wrong and this plan needs rewriting before any code changes.

---

## Phase 2: Refactors that are invisible on a full stack

Both changes below are prerequisites for conditionality but alter no behaviour
while all five services are deployed — so they can be validated against the
existing install before anything becomes conditional.

### Tasks

- [ ] Add detection facts to `034-setup-grafana.yml`: `k8s_info` probes for the
      Loki, Tempo and OTel Collector services, registered as
      `loki_present` / `tempo_present` / `otel_present`. Probe the **Service**, not
      the Pod — a datasource needs a resolvable endpoint, not a running pod.
- [ ] Replace every positional datasource proxy path with a UID-based one:
      `/api/datasources/proxy/1/…` → `/api/datasources/proxy/uid/prometheus/…`,
      likewise `uid/loki` and `uid/tempo` (tasks 10, 11, 12, 13, 16, 19). The UIDs
      are already declared in `034-grafana-config.yaml`.
- [ ] Print the three detected facts in task 1's banner, so the deploy log says
      which datasources it is about to provision.

### Validation

- [ ] `uis deploy grafana` on a **full** stack still passes end to end, with every
      datasource check reporting PASS as before
- [ ] The banner reports all three services present

---

## Phase 3: Conditional datasources + metadata fix

### Tasks

- [ ] Convert `manifests/034-grafana-config.yaml` to a Jinja template
      (`034-grafana-config.yaml.j2`) and render it to a temp path before the Helm
      task, wrapping the Loki and Tempo datasource entries in
      `{% if loki_present %}` / `{% if tempo_present %}`.
      *Alternative if templating a manifest is unwelcome:* keep the static file as
      the base and pass a computed `datasources` map via the Helm task's inline
      `values:`, which takes precedence over `values_files:`. Templating is
      preferred — it keeps the values file readable as one document.
- [ ] Reduce `SCRIPT_REQUIRES` to `"prometheus"` in `service-grafana.sh`
- [ ] Update the values file's header comment block, which currently states
      Loki and Tempo as prerequisites (lines 18–22)

### Validation

- [ ] With Prometheus only: Grafana starts, `GET /api/datasources` returns exactly
      one entry, `uid=prometheus`
- [ ] **No dangling datasources** — this is the failure mode that looks like
      success: a provisioned-but-unreachable Loki datasource makes Grafana appear
      configured while every query times out
- [ ] With the full stack: all three datasources present, unchanged from Phase 2

---

## Phase 4: Conditional validation gate

### Tasks

- [ ] Add `when: loki_present` to tasks 11, 14, 15, 16; `when: tempo_present` to
      tasks 12, 17, 18, 19
- [ ] Gate the OTLP-push tasks (14, 17) on `otel_present` as well as the store
      being present — pushing through a collector that is not deployed cannot work
- [ ] Rewrite task 20's `when:` and message so each store is asserted **only if it
      was expected**. Prometheus stays unconditionally required; Grafana without a
      metrics datasource is not a meaningful install.
- [ ] Same treatment for the task 29 summary — report `not installed` rather than
      `FAIL ❌` for an absent store, so the log does not read as a broken deploy

### Validation

- [ ] Prometheus-only: playbook completes, summary shows Loki/Tempo as
      `not installed`, exit 0
- [ ] Prometheus + Loki: Loki checks run and pass, Tempo reported not installed
- [ ] Full stack: identical output to Phase 2's baseline
- [ ] **Negative test:** deploy Loki, then delete its Service and redeploy Grafana
      — the run must fail, not skip. `when:` conditions must reflect what is
      *present*, never suppress a genuine failure.

---

## Phase 5: Dashboards match the datasources

### Tasks

- [ ] Split `035-grafana-test-dashboards.yaml` by signal, so the Logs and Traces
      test dashboards deploy only with their datasource
- [ ] Decide `036-grafana-sovdev-metrics.yaml`'s fate — it mixes 8 Prometheus
      panels with 4 Loki panels in one dashboard. Either split it or accept
      degraded panels on a metrics-only install; **splitting is preferred**, since
      broken panels in a shipped dashboard are how users conclude the platform is
      broken.
- [ ] Make task 23's `>= 4` ConfigMap assertion a function of which dashboards
      were actually deployed
- [ ] Gate the test-data generators (tasks 24, 25) on `otel_present`

### Validation

- [ ] Metrics-only: every deployed dashboard renders with no datasource errors
- [ ] Full stack: all four dashboards deploy as before

---

## Acceptance Criteria

- [ ] `uis deploy prometheus && uis deploy grafana` succeeds on a clean cluster
- [ ] Grafana starts with a working Prometheus datasource and **no dangling
      Loki/Tempo datasources**
- [ ] `uis stack install observability --skip-optional` succeeds (closes CLI-F1)
- [ ] `uis stack install observability` (full) produces a deployment
      indistinguishable from today's
- [ ] Every datasource proxy call is UID-based; `grep -c 'proxy/[0-9]'` in
      `ansible/playbooks/` returns 0
- [ ] The three intermediate combinations are exercised: `prometheus`,
      `prometheus+loki`, `prometheus+loki+tempo`

**Expected-fail before** (from Phase 1): `uis deploy grafana` dies at
`check_dependencies`; with metadata relaxed it dies at playbook task 20.

---

## Implementation Notes

### Do the phases in order — Phase 2 is the safety net

Phases 2 and 3 look mergeable and are not. The positional→UID proxy change is the
one edit that **silently misbehaves** rather than failing loudly: with
conditional datasources and positional IDs, `/proxy/2` on a metrics-only install
addresses whatever happens to be second. Landing it while the full stack is still
deployed means it can be verified against known-good output first.

### Two problems this plan deliberately does not fix

**1. VERIFY 13 in `u10-verify-observability-tasks.yml` hard-asserts that Grafana
has both a `tempo` and a `loki` datasource.** This plan makes that assertion
wrong. It is not fixed here because the file **has no caller** (CLI-F8) — it
cannot fail today. Making it profile-aware belongs to
`PLAN-cli-stack-001-test-harness`, which is what wires it in. Note the ordering
trap: whoever ships the harness inherits an assertion this plan already
invalidated.

**2. The Loki datasource URL collides with CLI-F6.** It points at
`loki-gateway.monitoring.svc.cluster.local:80`, while CLI-F6 recommends disabling
Loki's `gateway` in the small profile — an nginx proxy that in-cluster
SingleBinary access does not need. **Doing both breaks the Loki datasource.**
Whoever implements the small profile must repoint this URL at the Loki service
directly and verify the port; that work belongs to
`PLAN-cli-stack-003-sizing`, but it is recorded here because this is the file
that has to change.

### Scope

This makes Grafana *installable* in reduced configurations. It does not add
`--profile`, does not resize anything, and does not make production observability
more useful — see the scope limit in Part 5 of the investigation.

---

## Files to Modify

| File | Change |
|---|---|
| `provision-host/uis/services/observability/service-grafana.sh` | `SCRIPT_REQUIRES` → `"prometheus"` |
| `ansible/playbooks/034-setup-grafana.yml` | detection facts; UID-based proxy paths; `when:` on tasks 11–12, 14–19, 24–25; rewrite task 20 gate and task 29 summary; render templated values |
| `manifests/034-grafana-config.yaml` | → `.j2`; conditional Loki/Tempo datasource entries; correct the prerequisites comment |
| `manifests/035-grafana-test-dashboards.yaml` | split by signal |
| `manifests/036-grafana-sovdev-metrics.yaml` | split Prometheus and Loki panels |

Not modified, but affected — see Implementation Notes:
`ansible/playbooks/utility/u10-verify-observability-tasks.yml` (VERIFY 13).
