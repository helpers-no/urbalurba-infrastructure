# Monitor the components that are not in the cluster

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Active — Phase 1 done on the reference installation; Phases 2–4 open

**Goal**: The parts of a production install that live outside Kubernetes — the
hypervisor, an external database, object storage — are visible in metrics, not
just as an up/down dot.

**Investigation**: [INVESTIGATE-system-observability](./INVESTIGATE-system-observability.md)
— finding **OBS-F4**

**Related**:
- [PLAN-system-observability-002-alert-baseline](./PLAN-system-observability-002-alert-baseline.md)
  — shipped. Its capacity rules are written against `node_*` metrics and will
  cover these hosts automatically once they are scraped
- [PLAN-system-dependencies-shim-services](./PLAN-system-dependencies-shim-services.md)
  — the same "declare what is outside" problem, for reachability rather than metrics

**Priority**: High for production installs, irrelevant for a laptop

---

## Problem

Prometheus scrapes eight jobs, all inside the cluster. Everything the cluster
*depends on* is invisible to it:

| Component | Metrics today |
|---|---|
| The hypervisor host | none — no exporter installed |
| External PostgreSQL | none |
| External object storage | none |
| The vault, the registry cache, the NAS | none |

The external watchdog answers *"is it answering?"* for these. Nothing answers
*"is it about to stop answering?"*.

**This is the wrong way round for a self-hosted platform.** The in-cluster
workloads are replaceable; the ZFS pool holding every volume is not. On the
reference installation that pool moved from 5% to 9% during a single day's work,
and nothing would have said a word about it at 95%.

⚠️ For a developer on Rancher Desktop there is nothing outside the cluster, and
this plan is a no-op. It is production-only, which is exactly why it was the last
gap to be noticed.

---

## Phase 1: The hypervisor host

Highest value, because everything else runs on it.

### Tasks

- [x] 1.1 `prometheus-node-exporter` installed ✓
- [x] 1.2 ⚠️ **Bound to the backplane, not `0.0.0.0`** ✓ — verified both ways:
      `200` from the backplane, connection refused from the LAN.

      This needed two attempts, and the failed one is the interesting part. A
      systemd drop-in setting `Environment=ARGS=...` was **silently overridden**
      by the packaged unit's `EnvironmentFile=/etc/default/prometheus-node-exporter`,
      which sets `ARGS=""`. The service came up healthy, served metrics, and
      listened on `*:9100` — handing a full inventory of the host to every device
      on the LAN while looking entirely correct. Set it in the packaged defaults
      file instead of fighting the unit.
- [x] 1.3 Scraped over the backplane ✓ — monitoring traffic cannot leave the
      hypervisor and depends on nothing hosted
- [x] 1.4 ZFS collector active ✓ — 687 `node_zfs_*` series, and `/tank` reports
      874 GB available

### Validation

✅ **Done.** `up{job="external-hosts"} = 1`, and the rules cover it with **zero
changes**:

```
job=kubernetes-service-endpoints   filesystems evaluated:  3
job=external-hosts                 filesystems evaluated: 15
```

`predict_linear` on the pool returns 873.4 GB free in 24h — no concern today,
which is the right time to have the forecast rather than the wrong one.

---

## Phase 2: A declared list, not a hand-edited config

### Tasks

- [x] 2.1 Targets come from `.uis.extend/prometheus-targets.yaml` ✓, rendered
      into the scrape config by the playbook — the same shape as
      `.uis.extend/monitors.yaml`, so there is one idea to learn rather than two
- [x] 2.2 Absent ⇒ nothing extra is scraped ✓ — the playbook reports
      "none declared" rather than failing
- [x] 2.3 `why:` required and **enforced** ✓ — the deploy fails with a message
      naming the offending target, rather than accepting it

### Validation

✅ **Done.** `uis deploy prometheus` reports
`Scraping Alertmanager plus 1 declared external target(s). odin-hypervisor`, and
the job appears as `odin-hypervisor 1/1 up` — named from the declaration.

The product manifest now contains **zero** occurrences of the installation's
addresses. The whole scrape config is generated: Alertmanager always, declared
targets when present.

---

## Phase 3: The data services

### Tasks

- [ ] 3.1 `postgres_exporter` for an external PostgreSQL — connection saturation,
      replication lag, transaction age
- [ ] 3.2 Object storage: most S3 implementations expose Prometheus metrics
      natively, so this is a scrape target rather than an exporter
- [ ] 3.3 ⚠️ Credentials for exporters come from `urbalurba-secrets`, never from
      the scrape config, which lands in a ConfigMap

### Validation

Grafana shows database and storage health for components the cluster does not run.

---

## Phase 4: Backup freshness — and reconciling it with the watchdog

The investigation calls "last successful backup older than N hours" the single
most valuable alert a self-hosted platform can have.

### Tasks

- [ ] 4.1 ⚠️ **Check what already covers this before building anything.** On the
      reference installation the external watchdog already has push heartbeats
      for every backup job, wired to fire only after each job's own success
      check. That is arguably a *better* signal than a metric, because it proves
      the job ran rather than that a file exists
- [ ] 4.2 Decide deliberately: either the watchdog owns backup freshness and this
      plan does not duplicate it, or metrics own it and the heartbeats are
      retired. **Not both** — two systems paging for the same failure is how
      people learn to ignore one of them
- [ ] 4.3 Whichever wins, document which one owns it

### Validation

Exactly one system alerts when a backup stops. Verified by stopping one.

---

## Acceptance Criteria

- [x] The hypervisor's disk and memory are visible in Grafana ✓
- [x] Pool capacity trends, so `predict_linear` can warn before it is full ✓
- [x] `PLAN-002`'s existing rules cover external hosts with no rule changes ✓
- [x] Host metrics are **not** exposed to the LAN ✓ — verified by trying
- [x] External targets are declared in `.uis.extend`, not helm values ✓
- [x] A stock install scrapes nothing extra ✓
- [ ] Exactly one system owns backup-freshness alerting

---

## Implementation Notes

**Reuse the alert rules rather than writing host-specific ones.** `PLAN-002`'s
capacity rules already match on `node_filesystem_*` without a cluster-specific
selector. If adding a host requires new rules, the original rules were written
too narrowly and that is worth fixing instead.

**Binding matters more than it looks.** A node exporter on `0.0.0.0:9100` hands
every device on the network a detailed inventory of the host. The backplane
already exists for exactly this class of traffic.

**Do not scrape the hypervisor's management API for capacity.** It reports what
the hypervisor thinks; the node exporter reports what the kernel sees. When those
disagree the kernel is right, and disagreement is itself the interesting case.
