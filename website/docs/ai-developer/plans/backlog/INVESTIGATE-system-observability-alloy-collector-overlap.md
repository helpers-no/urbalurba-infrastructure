# Investigate: the Alloy decision promised 5 components → 4, and delivered 6

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Created**: 2026-08-22

## Status: Backlog

**Goal**: Act on the consequences the Alloy decision recorded and nobody followed
up — and settle the collector's future against the multi-cloud requirement rather
than against a component count.

**Recommendation already reached (2026-08-22, with Terje): KEEP the collector.**
The consolidation should be **abandoned deliberately**, not honoured. Reasoning in
*The recommendation* below. What remains open is the work it implies, not the
direction.

**Why now** (Terje, 2026-08-22): Alloy was added over the summer by an agent
without oversight. Reviewing it
([PLAN-service-alloy-convention-review](./PLAN-service-alloy-convention-review.md))
showed the *choice* was sound and well-evidenced. This file is about the part
that was written down and never done.

**Parent**: [INVESTIGATE-system-observability](./INVESTIGATE-system-observability.md)
**Related**: [PLAN-system-observability-001-log-collection](./PLAN-system-observability-001-log-collection.md)

⚠️ **`PLAN-system-observability-005-app-telemetry` does not exist.** The parent
investigation lists it as a planned child; 001, 002, 003, 004 and 006 were
written and 005 never was. An earlier revision of this file cited it as though it
existed. It is the missing piece this investigation most needs — see Q6.

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

## The recommendation: the collector is the portability seam

Terje, 2026-08-22: *"we must also peek into the future. As the plan is to get uis
working on azure kubernetes and use their logs systems. The developer that write
code should be able to run his code on rancher during development and in azure,
google, aws in production."*

That requirement decides this, and it decides it the opposite way to a
component-count argument.

**What must not change is what the developer's code talks to.** An application
emits OTLP to a fixed in-cluster endpoint. That endpoint is identical on Rancher
Desktop, AKS, GKE and EKS. Only what the collector *forwards to* differs:

```
app ──OTLP──▶ otel-collector.monitoring:4317 ──┬─▶ tempo/loki/prometheus   (Rancher Desktop)
                    ▲                          ├─▶ Azure Monitor           (AKS)
         never changes                         ├─▶ Cloud Trace/Logging     (GKE)
                                               └─▶ CloudWatch / X-Ray      (EKS)
```

This is the rule UIS already applies to PostgreSQL and MinIO — **the interface
must be identical; the topology may differ.** The collector is where that
topology difference is absorbed, and it is the only component that can absorb it
*without touching application code*.

### The two components answer different questions, and should diverge

| | Concern | Likely on AKS |
|---|---|---|
| **alloy** | *infrastructure* logs — scraping container stdout | **replaced** by Container Insights or the cloud's own agent |
| **otel-collector** | *application* telemetry — the OTLP contract | **stays**; only its exporters change |

Merging them would be actively harmful to the cloud plan:

- it couples the application's telemetry endpoint to a **DaemonSet**, when the
  portable thing is a stable Service name;
- it fuses an **environment-specific** concern (infra log scraping, which the
  cloud provider may do for you) with an **environment-invariant** one (the OTLP
  contract apps are written against);
- on AKS you would plausibly drop Alloy and keep the collector. That is
  impossible if they are the same component.

**So "5 components to 4" is withdrawn.** It was a reasonable prediction made
before the multi-cloud requirement existed. Making it true now would trade a
portability seam for one fewer Deployment.

---

## The required/optional flags are inverted

Terje, 2026-08-22, stating it as a requirement rather than a preference:

> *"No one will ever write directly, all logging will go otlp. That is a
> requirement. For rancher desktop and proxmox we deliver everything. But on
> azure, google, aws we go into production and there will probably already be
> existing logging systems. So in the case for cloud providers we will log via
> otel, but we might not deliver the grafana, loki stuff."*

That fixes each component's status, and the current configuration says the
opposite of what it should.

| | Status in every environment | Delivered by UIS |
|---|---|---|
| **otel-collector** | **REQUIRED** — it *is* the interface | always |
| prometheus, loki, tempo, grafana | **OPTIONAL** — the environment may already provide them | Rancher Desktop + Proxmox yes; cloud maybe not |

What is configured today:

```
stack definition:   5. otel-collector (optional)
service-grafana.sh: SCRIPT_REQUIRES="prometheus loki tempo otel-collector"
```

**Both backwards.** The one component that must exist everywhere is flagged
skippable, and the components UIS may not ship on Azure are treated as
mandatory. Verified by removing otel-collector and deploying grafana:

```
✗ Dependency error: Required service 'otel-collector' is not deployed
```

### This is stage-1 work, not stage-3

The sequencing is Rancher Desktop → Proxmox → cloud, and the cloud story is
deliberately not being designed yet. But these flags are wrong **today**, on
Rancher Desktop, and `--skip-optional` is broken **today**. Correcting them is
not designing for Azure; it is describing what the stack already is.

After the correction, `uis stack install observability --skip-optional` stops
being a broken command and becomes **exactly the cloud shape**: collector up,
backend absent.

### The mechanism for "backend provided externally" already exists

UIS does not need new machinery for the cloud case. It is the same convention
PostgreSQL and MinIO use — a Service carrying the real name and labels, so
consumers cannot tell whether the thing runs in-cluster or elsewhere. On Azure,
`loki-gateway.monitoring` could front Azure Monitor exactly as
`postgresql.default` fronts the external database.

That pattern is owned by
[PLAN-system-dependencies-shim-services](./PLAN-system-dependencies-shim-services.md).
Nothing here should invent a second one.

---

## Open questions

- **Q1. Does anything actually send OTLP to the collector today?** If no
  application emits telemetry, the collector is running for a use case that does
  not yet exist. Check the reference installation as well as a dev cluster —
  `urbalurba-platform` is Temporal-based and may.
- **Q2. ~~Should Alloy receive OTLP instead?~~ ANSWERED: no.** See the
  recommendation above. Kept in the list because the *reasoning* matters more
  than the answer: it is architectural, not cosmetic.
- **Q3. Why does grafana declare a dependency on otel-collector?** Its
  datasources are prometheus, loki and tempo. Establish whether anything real is
  behind it before removing it — the inversion above assumes it is spurious, and
  that assumption should be checked rather than inherited.
- **Q4. What reads collector metrics?** Consequence 2, unanswered. Enumerate
  shipped dashboards and alert rules; anything keyed on collector-specific series
  breaks if the collector goes, and may already be stale.
- **Q5. What does removal cost, and does anything gain?** Requests/limits for
  both, on a stack that must fit a laptop. If Alloy absorbs OTLP the saving is
  one Deployment; if not, there is no saving to have.
- **Q6. PLAN-005 must be written, and this investigation is now its input.** The
  dev→prod app-telemetry story does not exist as a plan. It should define: the
  OTLP endpoint applications code against, per-environment exporter config living
  in `.uis.extend/` the way external services already do, and what a developer
  changes when moving from Rancher Desktop to AKS (ideally: nothing).

---

## What this investigation must produce

In order:

1. **PLAN-005 — app telemetry.** The OTLP contract and the per-environment
   exporter story. Everything else depends on it.
2. **Correct the required/optional inversion** — see above. Three changes:
   `otel-collector` becomes required in the stack; `grafana` drops
   `otel-collector` from `SCRIPT_REQUIRES` (it needs datasources, not a
   collector — Q3); prometheus/loki/tempo/grafana become optional. This fixes
   `--skip-optional` as a side effect and makes the cloud shape expressible.
3. **Answer Q4** — what reads collector metrics — and either update the
   dashboards/alerts or state that none are affected.
4. **Document Alloy as environment-specific**, not universal. It is the piece
   most likely to be replaced by a cloud provider's own agent.

**Not produced: a removal plan.** The collector stays.

---

## Notes

**Do not treat "the agent said 4 components" as a commitment to honour.** The
sentence was a prediction about a consolidation nobody performed. Judged on its
merits *now*, against a requirement that did not exist when it was written, the
consolidation is the wrong move. The prediction is withdrawn rather than
outstanding — which is a better outcome than either doing it or leaving it to be
rediscovered as debt every time someone counts the components.

**The pattern worth naming.** A decision recorded its own consequences honestly,
and the consequences were never scheduled. The decision doc is not wrong; it is
incomplete in a way that reads as complete. Same shape as the summer's other
recurring finding — *an allowlist that new things never join* — here it is *a
caveat that no plan ever inherits*. Worth asking whether recorded consequences
should become tasks in the plan they belong to, rather than prose in the
investigation that spawned it.
