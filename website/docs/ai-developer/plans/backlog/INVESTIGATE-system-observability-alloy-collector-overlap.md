# Investigate: Alloy and the OTel Collector — the consequences nobody scheduled

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

**Priority**: Medium — raised in practice by the inversion below, which is broken
on Rancher Desktop **today** and is not gated on any cloud work.

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
`loki.process` / `loki.write`. That part is measured.

That Alloy *could* do the collector's job is **not** measured here: it follows
from Alloy being an OTel Collector distribution upstream, and was not verified
against the chart version UIS deploys or its `otelcol.*` component surface.
Since the recommendation is not to do it, this does not need resolving — but it
should not be quoted as established.

So the stack went from 5 components to **6**, not 4, and both run on every
install.

⚠️ **The "5 → 4" arithmetic was never checked, including by this file, which
quoted it twice as evidence.** Counting the stack before Alloy — prometheus,
tempo, loki, otel-collector, grafana — gives 5. Alloy replacing the collector
gives prometheus, tempo, loki, alloy, grafana, which is **5, not 4**. Either the
original "5" counted something not visible in the stack definition, or the claim
never added up. Not load-bearing now that the prediction is withdrawn, but worth
knowing that the number was repeated rather than verified — by the original
decision and then by this investigation.

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

A documented flag on a documented stack, guaranteed to fail.

*(An earlier revision said which fix is right "depends on the answer below". It
no longer does — the inversion section settles it. Kept here rather than filed
separately because the fix is one change to the same two files.)*

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
| **otel-collector** | **REQUIRED** — an OTLP endpoint must exist | ⚠️ see below |
| prometheus, loki, tempo, grafana | **OPTIONAL** — the environment may already provide them | Rancher Desktop + Proxmox yes; cloud maybe not |

⚠️ **"UIS always delivers the collector" is an assumption, not something Terje
said.** The requirement stated was that all logging goes via OTLP and that on
cloud *"we might not deliver the grafana, loki stuff"*. Whether UIS **ships** a
collector on AKS, or points applications at an OTLP endpoint the customer already
runs, is undecided — a production Azure tenant with an existing observability
stack plausibly has one. What is settled is that **an OTLP endpoint at a stable
address must exist in every environment**; who provides it is Q7.

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

## ANSWERED on the running Proxmox stack (ops, 2026-08-22)

Measured live on asgard — prometheus API, the collector's `:8888`, live
ConfigMaps. Full reply: `ai-developer/for-assist-observability-collector-answers.md`
in the home repo.

### Q1 ⭐ — OTLP has a **validated-but-dormant** consumer

```
otelcol_receiver_accepted_log_records{receiver="otlp",transport="http"}   223
otelcol_receiver_accepted_spans{receiver="otlp",transport="grpc"}         160
otelcol_receiver_accepted_metric_points{receiver="otlp",transport="grpc"}   5
otelcol_process_uptime                                                  ≈ 17.5 days
```

And the pipeline **fanned it out correctly** — 223 logs to `otlphttp/loki`, 160
spans to `otlp/tempo`, 5 metric points to `prometheusremotewrite`.

**Neither branch I offered was right.** Two samples 35 s apart were identical, and
those totals over 17.5 days are tiny — so this is not a climbing stream, and not
"correct-but-unused" either. Real spans and logs went in and reached Tempo and
Loki. The OTLP contract is **proven end-to-end, with no continuous producer**.

Consequence: **PLAN-005 is not urgent — but it is validated rather than
speculative.** That is a stronger footing than "nobody uses it", and a weaker
urgency than "something depends on it now". Safe to wait for Proxmox to settle.

*(ops could not identify the emitter from counters alone; gRPC spans + HTTP logs
suggest an instrumented app. A deeper dig if it ever matters.)*

### Q4 — nothing reads `otelcol_*`, and it is worse than stale

- **Prometheus does not scrape the collector at all** on asgard — zero
  `otelcol_*` series, no matching scrape target.
- **No ConfigMap, dashboard or rule references `otelcol_*`** anywhere; no
  PrometheusRule CRDs either.

So changing the collector's role affects **zero** dashboards and **zero** alerts.
The Consequence-2 caveat turns out to have had nothing to act on — the metrics
nobody updated were also metrics nobody collected.

> ⚠️ **Side-finding worth its own attention: the collector's health is
> unmonitored.** If it silently stops receiving OTLP, nothing alerts — only pod
> liveness would notice, and a running collector that accepts nothing looks
> identical to a running collector with no traffic. Given Q1 shows exactly that
> state today, there is no way to tell "dormant" from "broken" from the outside.
> Independent of PLAN-005 and of this investigation's direction.

### Q3 — runtime confirms Grafana does not need the collector

Grafana's datasources are prometheus, loki and tempo. Traces reach Tempo *via*
the collector, but **Grafana reads Tempo, not the collector**. Dropping
`otel-collector` from `SCRIPT_REQUIRES` breaks nothing observable.

⚠️ **Caveat ops correctly refused to close**: asgard shows runtime behaviour, not
*history*. If the dependency was added as deploy-ordering glue for some past
reason, only the code history would show it. My "spurious" assumption survives
contact with the running system; it has not been proven about the original
intent.

### Both distrust-checks — CONFIRMED

- **"Alloy has no OTLP receivers"** ✅ asgard's live `monitoring/alloy` ConfigMap
  contains only `loki.source` / `loki.process` / `loki.write`. No `otelcol.*`.
  The "they do different jobs" finding stands on the production stack, not just a
  laptop.
- **"`--skip-optional` is inverted"** ✅ present on asgard too, not worked around
  locally.

### The `.uis.extend/` pattern — generalises, with one limit I had missed

I suggested asgard's per-environment config pattern was the shape PLAN-005 needs.
ops confirmed the **mechanism** transfers — a declarative per-environment file,
with `why`/`role` fields that force intent and keep it auditable — and then
corrected the part I got wrong:

> ⚠️ `prometheus-targets.yaml` is a **pull / scrape-targets** pattern. PLAN-005's
> per-environment exporters for Azure Monitor is a **push** model. The per-env-file
> mechanism transfers; pull-vs-push does not. **Scrape-targets and push-exporters
> are siblings, not the same knob.**

That distinction belongs in PLAN-005 from the start. Assuming one config shape
covers both would have produced a design that fits Proxmox and breaks on Azure.

⚠️ Also flagged: ops could not trace **how `prometheus-targets.yaml` is injected**
into Prometheus in one pass. The declarative-per-env-file *idea* is the reusable
part; confirm the injection mechanism before copying it.

### Loki's probe leftover — not present on asgard

Loki's `job` values there are only `["loki.source.kubernetes.pods"]` — no
`loki-validation`. Either retention aged it out or asgard's probe path differs.
The collector's OTLP logs carry resource attributes rather than a `job` label, so
they would not collide regardless. The Alloy assertion fix remains right for the
general case; the leftover simply does not manifest on that installation.

---

## Open questions

- **Q1. ~~Does anything send OTLP?~~ ANSWERED — validated-but-dormant.** See above.
- **Q2. ~~Should Alloy receive OTLP instead?~~ ANSWERED: no.** See the
  recommendation above. Kept in the list because the *reasoning* matters more
  than the answer: it is architectural, not cosmetic.
- **Q3. ~~Why does grafana declare a dependency?~~ ANSWERED at runtime — it does
  not need one.** History still unchecked; see the caveat above.
- **Q4. ~~What reads collector metrics?~~ ANSWERED — nothing.** See above. Left a
  new finding behind it: collector health is unmonitored.
- **Q5. ~~What does removal cost, and does anything gain?~~ MOOT.** Answered by
  Q2: removal is not on the table, and by its own terms there was no saving to
  have unless Alloy absorbed OTLP. Kept struck through rather than deleted so the
  question is not re-asked.
- **Q7. On cloud, does UIS ship a collector or use the customer's?** See the
  ⚠️ above. Stage-3 work, recorded now so the assumption is visible rather than
  inherited. Affects nothing at stages 1–2, where UIS delivers everything.
- **Q6. PLAN-005 must be written, and this investigation is now its input.** The
  dev→prod app-telemetry story does not exist as a plan. It should define: the
  OTLP endpoint applications code against, per-environment exporter config living
  in `.uis.extend/` the way external services already do, and what a developer
  changes when moving from Rancher Desktop to AKS (ideally: nothing).

---

## What this investigation must produce

In order — **resequenced 2026-08-22 on ops' evidence.** The inversion fix is now
confirmed safe (Q4: nothing depends on the collector's current role) and repairs a
command broken today; PLAN-005 is confirmed *not* urgent (Q1: no continuous
producer). So the small certain thing goes first:

1. **Correct the required/optional inversion** — see above. Three changes:
   `otel-collector` becomes required in the stack; `grafana` drops
   `otel-collector` from `SCRIPT_REQUIRES` (it needs datasources, not a
   collector — Q3); prometheus/loki/tempo/grafana become optional. This fixes
   `--skip-optional` as a side effect and makes the cloud shape expressible.
2. **PLAN-005 — app telemetry.** Not urgent, and now written against a *proven*
   architecture. Must carry the pull-vs-push distinction from the start.
3. **Monitor the collector.** New, from Q4's side-finding — there is currently no
   way to distinguish a dormant collector from a broken one.
4. **Document Alloy as environment-specific**, not universal. It is the piece
   most likely to be replaced by a cloud provider's own agent.
5. ~~Answer Q4~~ — done; nothing depends on collector metrics.

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
