# Investigate: an external watchdog — does Uptime Kuma overlap the observability stack?

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: Decide whether UIS needs an availability watchdog that runs *outside*
the platform, and whether that duplicates the in-cluster observability stack.

**Last Updated**: 2026-08-07

**Related**: [INVESTIGATE-system-observability](./INVESTIGATE-system-observability.md)
— that covers depth *inside* the cluster; this covers survival *outside* it.

---

## Questions to Answer

1. Does an external watchdog duplicate Prometheus/Grafana/Loki?
2. If not, where is the boundary between them?
3. Where must it run, and what can it therefore not see?
4. What is the failure mode of the watchdog itself?

---

## Current State

The reference deployment runs the full stack on `asgard` — Prometheus,
Alertmanager, Grafana, Loki, Tempo, otel-collector, node-exporter,
kube-state-metrics. All healthy.

It has alerted on nothing, ever:

```
GET /api/v1/rules  ->  {"status":"success","data":{"groups":[]}}
PrometheusRule CRs ->  0
log agents (promtail/alloy/fluent/vector) -> 0
```

---

## Findings

### F1 — Every incident this week was found by a human asking a question

| Incident | Duration before noticed | How it was found |
|---|---|---|
| iMac root filesystem went read-only | hours | a write failed mid-task |
| M4 sleeping in 9–16 min cycles, repeatedly | days | went looking |
| Enrichment pipeline stopped | **8.4 hours** | the operator asked "is traffic flowing?" |
| 1590 `llava:7b` failures (78% error rate) | 12 h | same query |
| Tailnet path to the database dropped | minutes | an SSH session hung |
| A CNPG replica orphaned when its primary died | **82 days**, still reporting "Cluster in healthy state" | found while removing it |

Not one of these produced an alert. The last is the sharpest: a component
reported itself healthy for 82 days while replicating from a host that no longer
existed.

### F2 — The overlap is real but shallow

Prometheus with `blackbox_exporter` can do HTTP/TCP/ICMP probes and alert on
them. That is genuinely the same capability. So on paper, yes, it overlaps.

In practice the overlap is **currently zero**, because the in-cluster stack has
no rules. But even fully configured, the duplicated part — "is this endpoint
answering" — is the cheapest thing either system does. It is not where the cost
or the value lies.

### F3 — ⚠️ The decisive argument: a monitor inside the cluster cannot report the cluster being down

This is the same principle as
[production decision 4](../../../production/index.md) — *a backup job must not
depend on the thing it backs up* — applied to monitoring. The in-cluster stack
is blind precisely when it matters most:

| Failure | In-cluster stack | External watchdog |
|---|---|---|
| One pod crashlooping | ✅ sees it | ✅ if it fronts a probed endpoint |
| Node under memory pressure | ✅ rich detail | ❌ |
| k3s API down | ❌ **dies with it** | ✅ |
| The VM is off / host rebooted | ❌ **dies with it** | ✅ |
| Storage backend unreachable | ❌ likely dies with it | ✅ |
| A batch job silently stopped | ❌ nothing emits | ✅ **heartbeat expiry** |
| The house lost power | ❌ | ❌ (see F5) |

The two systems answer different questions. In-cluster answers *why*; external
answers *whether*. Neither substitutes for the other.

### F4 — Heartbeat monitoring is the capability nothing else provides

The 8.4-hour pipeline stall (F1) is the important case, because **nothing was
broken**. No pod crashed, no endpoint went down, no error rate spiked. Work
simply stopped arriving. Metrics-based alerting struggles with absence; a
push/heartbeat monitor — "tell me every N minutes that you are alive, and page
me when you stop" — catches it directly.

The same applies to the backup chain. "Last successful backup older than N
hours" is called out in
[INVESTIGATE-system-backup-and-scheduling](./INVESTIGATE-system-backup-and-scheduling.md)
as the highest-value alert a self-hosted platform can have, and it is a
heartbeat, not a metric.

### F5 — Where it runs determines what it can see, and there is no free lunch

| Location | Catches | Blind to |
|---|---|---|
| In the monitored cluster | pod/app failures | the cluster, the node, the host |
| **Another machine on the LAN** | cluster/host/VM failure, batch stalls | power cut, ISP outage |
| Outside the house (e.g. free-tier cloud) | all of the above | needs inbound reach or an overlay |

The reference deployment puts it on `assist` — a Raspberry Pi that is not part
of the monitored platform. That covers every incident in F1. It does **not**
cover a whole-house outage; that needs an off-site monitor and is a deliberate,
separate decision.

### F6 — "Who watches the watchdog" has no clean answer, only mitigations

If the watchdog dies, everything looks fine forever. Options, none free:

- **Accept it** — the watchdog is small and simple; the platform is not.
- **Dead-man's switch** — the watchdog pushes a heartbeat to a free external
  service; that service alerts if the push stops. Cheap, and closes the loop.
- **Mutual monitoring** — the in-cluster stack probes the watchdog. This is where
  a little duplication is genuinely correct.

Recommend the dead-man's switch, with mutual monitoring once the in-cluster
stack has any rules at all.

### F7 — Storage on the reference host: measured, and counter-intuitive

`assist` boots from a 29 GB microSD and has a 57.7 GB USB stick already carrying
Home Assistant, Z-Wave and `k3s-storage`, exposed as a `local-path-usb`
StorageClass. The assumption was that the stick would be faster and safer:

```
                    boot microSD      USB DataTraveler 3.0
sequential write    33.3 MB/s         6.9 MB/s      <- 5x SLOWER
4k sync writes      155/sec           136/sec       <- slightly slower
```

It is **not faster** — a cheap flash stick on a 5 Gbps port, with no DRAM cache.
It is also not obviously more durable. Its real advantages are **blast radius**
(it is not the boot device; wearing it out costs a stick, not a rebuild) and
capacity. Use it for that reason, not for speed.

At ~140 sync-writes/sec neither device wants a chatty SQLite workload, so
check interval and retention must be set deliberately rather than left at
defaults.

### F8 — UIS has no concept of this

`uis deploy` targets a cluster. A watchdog that must live outside the cluster it
watches is the same class of gap as the external database, object store, secret
store, registry cache and scheduler — the recurring **"components beside the
cluster"** class. It could be a UIS service deployed against a *different*
kubeconfig, but nothing in UIS expresses "this must not run where the rest runs".

---

## Options

### Option A: Configure `blackbox_exporter` in the existing stack instead

**Pros:** one system, one skill set, alerts already route through Alertmanager.
**Cons:** still inside the cluster, so blind to F3's bottom four rows. Solves the
duplication worry by keeping the blind spot. Heartbeat monitoring needs
Pushgateway plus custom rules — possible but fiddly.

### Option B: Uptime Kuma on a machine outside the platform

**Pros:** correct blast radius; push/heartbeat monitors are first-class; trivial
to run (~200 MB); a status page for free; notification channels built in.
**Cons:** a second system to maintain; SQLite on flash needs tuning; overlaps
~10% with Prometheus.

### Option C: Both, with a clear boundary

**Pros:** external answers *whether*, in-cluster answers *why*; each is used for
what it is good at. Small duplication is deliberate redundancy at the layer where
a single point of failure is unacceptable.
**Cons:** two alerting paths to keep from becoming noisy.

---

## Recommendation

**Option C**, implemented as Uptime Kuma on `assist`.

The overlap question resolves cleanly once the boundary is stated:

> **Uptime Kuma answers "is it up, and did the job run?" from outside.
> Prometheus/Grafana/Loki answer "why is it behaving like this?" from inside.**

Concretely: **do not** rebuild in-cluster metrics as Kuma monitors, and **do
not** rely on the in-cluster stack for availability of the cluster itself.

Two constraints that fall out of the findings:

1. It must not run on `asgard` or on Odin (F3).
2. Its own liveness needs a dead-man's switch (F6), or it is one silent failure
   away from being decorative — the exact failure the 82-day orphaned replica
   demonstrates.

---

## Next Steps

- [ ] `PLAN-service-uptime-kuma-001-deploy.md` — deploy on assist's k3s, USB-backed
- [ ] `PLAN-service-uptime-kuma-002-monitors.md` — the monitor set, incl. heartbeats
- [ ] `PLAN-service-uptime-kuma-003-alerting.md` — channels, escalation, dead-man's switch
