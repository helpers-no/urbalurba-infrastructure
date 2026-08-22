# Investigate: the Alloy decision promised 5 components → 4, and delivered 6

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Created**: 2026-08-22

## Status: Backlog

**Goal**: Decide whether Alloy should absorb the OTel Collector's role, keep them
separate deliberately, or something else — and act on the consequences the
original decision recorded and nobody followed up.

**Why now** (Terje, 2026-08-22): Alloy was added over the summer by an agent
without oversight. Reviewing it
([PLAN-service-alloy-convention-review](./PLAN-service-alloy-convention-review.md))
showed the *choice* was sound and well-evidenced. This file is about the part
that was written down and never done.

**Parent**: [INVESTIGATE-system-observability](./INVESTIGATE-system-observability.md)
**Related**: [PLAN-system-observability-001-log-collection](./PLAN-system-observability-001-log-collection.md),
[PLAN-system-observability-005-app-telemetry](./PLAN-system-observability-005-app-telemetry.md)

**Priority**: Medium

---

## Background: the decision was right, the follow-through did not happen

Choosing Alloy holds up. **Promtail reached end-of-life on 2 March 2026** —
Grafana ended support and moved development to Alloy, so it was not a candidate.
UIS had no log shipper at all (measured: `kubectl get pods -A | grep -iE
'promtail|alloy|fluent|vector'` → nothing), Loki held only its own canary
traffic, and this was a greenfield install rather than a migration. Resource cost
was checked, not waved through. That is a well-made call.

Two consequences were recorded alongside it. Neither was acted on.

### Consequence 1 — the consolidation

> Alloy is a vendor-neutral distribution of the OTel Collector and handles logs,
> metrics and traces, **so it also subsumes the standalone collector, taking the
> stack from 5 components to 4.**

Measured 2026-08-22, they do **different jobs as configured** and neither is
redundant:

| | Receives | Sends to |
|---|---|---|
| **otel-collector** | OTLP gRPC `:4317` + OTLP HTTP, from applications | tempo (traces), loki (logs), prometheus (remote write) |
| **alloy** | Kubernetes pod log files | loki |

`manifests/031-alloy-config.yaml` has **no OTLP receivers** — only
`loki.process` / `loki.write`. Alloy *could* do the collector's job; as
configured it does not.

So the stack went from 5 components to **6**, not 4, and both run on every
install.

### Consequence 2 — the metrics

> Alloy emits different metrics than Promtail or the collector; any dashboard or
> alert built on collector metrics needs updating.

Recorded as a caveat. No follow-up found. Whether any shipped dashboard or alert
rule reads collector metrics is **unknown** and is part of this investigation.

---

## A defect found while measuring this

**`uis stack install observability --skip-optional` cannot work.**

The stack marks otel-collector optional:

```
Services (in installation order):
  ...
  5. otel-collector (optional)
  6. grafana
```

Grafana hard-requires it:

```bash
SCRIPT_REQUIRES="prometheus loki tempo otel-collector"
```

Verified by removing otel-collector and deploying grafana:

```
ℹ Dependency 'prometheus' is deployed
ℹ Dependency 'loki' is deployed
ℹ Dependency 'tempo' is deployed
✗ Dependency error: Required service 'otel-collector' is not deployed
```

A documented flag on a documented stack, guaranteed to fail. This is independent
of the consolidation question and can be fixed either way — but *which* fix is
right depends on the answer below, so it is recorded here rather than filed
separately.

---

## Open questions

- **Q1. Does anything actually send OTLP to the collector today?** If no
  application emits telemetry, the collector is running for a use case that does
  not yet exist. Check the reference installation as well as a dev cluster —
  `urbalurba-platform` is Temporal-based and may.
- **Q2. Should Alloy receive OTLP instead?** Not a config tweak. Alloy is a
  **DaemonSet** (per-node); the collector is a **central gateway**. Making Alloy
  the receiver means every app talks to a node-local agent rather than one
  endpoint — different failure modes, different scaling, different app config.
- **Q3. Is grafana's dependency on otel-collector real?** Grafana needs
  datasources: prometheus, loki, tempo. It is not obvious why it needs the
  collector at all. If the dependency is spurious, the `--skip-optional` defect
  dissolves and the collector becomes genuinely optional.
- **Q4. What reads collector metrics?** Consequence 2, unanswered. Enumerate
  shipped dashboards and alert rules; anything keyed on collector-specific series
  breaks if the collector goes, and may already be stale.
- **Q5. What does removal cost, and does anything gain?** Requests/limits for
  both, on a stack that must fit a laptop. If Alloy absorbs OTLP the saving is
  one Deployment; if not, there is no saving to have.
- **Q6. Does PLAN-005 assume the collector?** The dev→prod app-telemetry story is
  exactly what the collector serves. Answering Q2 without reading that plan would
  settle its architecture by accident.

---

## What this investigation must produce

- A decision on Q2 with its reasoning, since it is architectural rather than
  cosmetic
- A fix for the `--skip-optional` defect consistent with that decision
- An answer to Q4, and either updated dashboards/alerts or a statement that none
  are affected
- If removal is chosen: a plan, not a deletion. otel-collector is a deployed
  service on the reference installation

---

## Notes

**Do not treat "the agent said 4 components" as a commitment to honour.** The
sentence was a prediction about a consolidation nobody performed. The question is
whether the consolidation is a good idea *now*, judged on its merits — not
whether to make an old sentence true retroactively.

**The pattern worth naming.** A decision recorded its own consequences honestly,
and the consequences were never scheduled. The decision doc is not wrong; it is
incomplete in a way that reads as complete. Same shape as the summer's other
recurring finding — *an allowlist that new things never join* — here it is *a
caveat that no plan ever inherits*. Worth asking whether recorded consequences
should become tasks in the plan they belong to, rather than prose in the
investigation that spawned it.
