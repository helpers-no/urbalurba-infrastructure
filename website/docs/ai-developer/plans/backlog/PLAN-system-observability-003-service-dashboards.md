# Ship a dashboard with the service

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Active — mechanism proven with one worked example; wiring into `uis deploy` outstanding

**Goal**: `uis deploy <service>` on a cluster with Grafana yields a dashboard for
that service, with no manual steps and nothing to import.

**Investigation**: [INVESTIGATE-system-observability](./INVESTIGATE-system-observability.md)
— finding **OBS-F5**

**Related**:
- [PLAN-system-observability-002-alert-baseline](./PLAN-system-observability-002-alert-baseline.md) — shipped
- [PLAN-system-observability-004-external-targets](./PLAN-system-observability-004-external-targets.md) — shipped; produced the metrics these panels use
- [PLAN-system-observability-006-service-probes](./PLAN-system-observability-006-service-probes.md) — the same idea for availability probes. **This plan and 006 should share one artifact convention, not invent two**

**Priority**: Medium

---

## Problem

Metrics arrive and alerts fire, but Grafana has **no curated view over any of
it**. A dashboard ConfigMap count of zero:

```
kubectl get cm -n monitoring -l grafana_dashboard | wc -l   →  0
```

So the platform can now tell you *that* PostgreSQL connections are saturating,
and there is nowhere to go and look at the trend. The answer today is to write a
PromQL query from memory in the Explore tab, which is a skill the person holding
the pager at 3am may not have.

**This is a smaller problem than it looks, and worth being honest about.** Alerts
are the thing that wakes you; dashboards are the thing you read once awake. That
is why this plan comes after 002 and 004, not before.

## The mechanism already exists

Grafana runs a sidecar that watches for ConfigMaps:

```
LABEL         grafana_dashboard
LABEL_VALUE   1
NAMESPACE     monitoring
```

So "shipping a dashboard" means writing a labelled ConfigMap. No Grafana API
calls, no credentials, no import step, and it survives a Grafana restart because
the sidecar re-reads them.

---

## Phase 1: The artifact

### Tasks

- [x] 1.1 A service may ship `services/<category>/dashboards/<id>.json` ✓ —
      `databases/dashboards/postgresql.json` is the first
- [ ] 1.2 Applied only when **both** that service and Grafana are deployed — a
      dashboard for something that is not installed is a broken panel, which is
      worse than no panel
- [x] 1.3 ⚠️ Panels reference only verified metrics ✓ — all nine were counted in
      Prometheus before a panel was written, and every panel was then queried
      after applying. **8 panels, 8 returning data, zero "No data"**
- [ ] 1.4 One artifact convention shared with `PLAN-006`'s probes, so a service
      has one observability contract rather than two competing ones

### Validation

`uis deploy postgresql` on a cluster with Grafana yields a working Postgres
dashboard with no manual steps.

---

## Phase 2: Worked examples

Start with what actually breaks, not with what is easy to graph.

### Tasks

- [x] 2.1 **postgresql** ✓ — reachability, connections against `max_connections`,
      longest transaction, cache hit ratio, per-database connections, commit rate,
      database sizes, deadlocks
- [ ] 2.2 A **platform overview** — pool capacity trend, cluster health, alert
      state. This is not per-service and needs somewhere else to live; it is the
      one an operator actually opens
- [ ] 2.3 Others as they earn it. Resist shipping a dashboard per service for
      completeness — every unused panel is maintenance

### Validation

✅ **Verified by querying every panel's expression**, not by looking at the
dashboard:

```
Reachable                      1 series     Connections per database      4 series
Connections used               1 series     Transactions committed / sec  7 series
Longest open transaction       1 series     Database size                 8 series
Cache hit ratio                1 series     Deadlocks / sec               9 series
```

The sidecar picked the ConfigMap up on its own: `Writing /tmp/dashboards/postgresql.json`.

---

## Acceptance Criteria

- [x] A dashboard appears with no import step ✓ — a labelled ConfigMap; the
      sidecar re-reads them, so it survives a Grafana restart by construction
- [ ] Applied automatically by `uis deploy`, rather than by hand as here
- [x] No panel references a metric the service does not produce ✓
- [ ] Dashboards for services that are not installed are not applied
- [ ] The convention is shared with `PLAN-006`, not parallel to it

---

## Implementation Notes

**Do not import community dashboards wholesale.** The popular Postgres dashboards
assume exporter flags and recording rules that are not enabled here, so most
panels render empty. An empty panel is worse than an absent one: it looks broken,
and people stop trusting the whole dashboard. Ship a small dashboard where every
panel works.

**Dashboards are documentation that goes stale silently.** A panel referencing a
metric that stopped being produced does not error, it just shows nothing —
`absence renders as green` in its Grafana costume. Any check should assert panels
return data, not that the ConfigMap exists.
