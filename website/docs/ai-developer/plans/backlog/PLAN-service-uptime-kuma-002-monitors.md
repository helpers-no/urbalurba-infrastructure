# Define what the watchdog watches

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: Every incident from the investigation's F1 table would be caught, and
nothing is monitored twice for the sake of it.

**Investigation**: [INVESTIGATE-service-uptime-kuma.md](./INVESTIGATE-service-uptime-kuma.md)
**Prerequisites**: `PLAN-service-uptime-kuma-001-deploy.md`

**Priority**: High

**Last Updated**: 2026-08-07

---

## Problem

A watchdog with the wrong monitors is worse than none: it produces confidence
without coverage. The monitor set must be derived from failures that actually
happened, not from what is easy to probe.

## Principle

> Probe the **thing a user depends on**, not the process that provides it.

A pod being `Running` is the in-cluster stack's job. Whether the endpoint answers
is this one's.

---

## Phase 1: Hosts and infrastructure

### Tasks

- [ ] 1.1 Odin host — Proxmox UI (TCP 8006)
- [ ] 1.2 `asgard` — the k3s API (TCP 6443). **This is the one the in-cluster
      stack structurally cannot report** (investigation F3)
- [ ] 1.3 `pg` — TCP 5432 on the backplane address `10.10.0.105`
- [ ] 1.4 `minio` — HTTP `/minio/health/live`
- [ ] 1.5 `bao` — HTTP `/v1/sys/health` (note: a sealed vault answers with a
      distinct status code; treat sealed as DOWN, not as healthy)
- [ ] 1.6 `registry` — HTTP `/v2/`
- [ ] 1.7 `nas` — TCP 445

### Validation

Stop one guest deliberately; confirm it goes red and recovers.

---

## Phase 2: Services users actually reach

### Tasks

- [ ] 2.1 LiteLLM `GET /v1/models` with the API key — **keyword match on a model
      name**, not just HTTP 200. It returned 200 while the database was broken
      and virtual keys were dead
- [ ] 2.2 Grafana, Temporal Web, Authentik, MinIO console — via their tailnet
      hostnames, which is how they are actually used
- [ ] 2.3 Home Assistant on assist itself

### Validation

User confirms each monitor turns red when its service is stopped.

---

## Phase 3: The Ollama backends

### Tasks

- [ ] 3.1 M1 `/api/version` via `192.168.68.70`
- [ ] 3.2 M4 `/api/version` via `192.168.68.58`, and after the holiday also its
      tailnet address
- [ ] 3.3 Set both to **notify only after 3 consecutive failures**

### Validation

The M4 sleeps in 9–16 minute cycles (investigation F1). These monitors must
record that pattern without paging for every nap. Review after 24 h: the graph
should show the cycles clearly while notifications stay quiet.

⚠️ Probing every 60s may keep a Mac awake — the same side effect the
`ollama-endpoint-manager` has. Decide deliberately whether that is wanted.

---

## Phase 4: Heartbeats — the capability nothing else provides

These catch *absence of work*, which metrics handle badly (investigation F4).

### Tasks

- [ ] 4.1 Push monitor **`enrichment-worker`**, expiry ~15 min. The worker calls
      its push URL each cycle. **This is the monitor that would have caught the
      8.4-hour stall**
- [ ] 4.2 Push monitor **`pg-dump`**, expiry ~26 h
- [ ] 4.3 Push monitor **`vzdump`**, expiry ~26 h
- [ ] 4.4 Push monitor **`restic-offsite`**, expiry ~26 h
- [ ] 4.5 Push monitor **`pgbackrest`**, expiry ~26 h
- [ ] 4.6 Add the `curl` push call to each job, **after** its success check, so a
      failed job does not report success

### Validation

Let one backup cycle run; all four report. Then deliberately skip one and
confirm it goes red at expiry.

> 26 h rather than 24 h leaves headroom for a late run without a false alarm —
> and note the daylight-saving hazard recorded in the backup investigation:
> avoid expiries that straddle 02:00–03:00 local.

---

## Acceptance Criteria

- [ ] Every row of the investigation's F1 table would now be caught
- [ ] No monitor duplicates something the in-cluster stack does better
- [ ] Backup and pipeline heartbeats are live
- [ ] The M4's sleep cycles are visible but do not page
- [ ] Each monitor has been seen to go red at least once

---

## Implementation Notes

**Probe from outside, by the address users use.** Monitoring `pg` on the
backplane checks the database; monitoring it via the shim would also exercise the
path that Temporal and Authentik depend on. Both are defensible — 1.3 chooses the
database itself, because the shim is covered indirectly by the service monitors
in Phase 2.

**Keyword matching matters more than status codes.** The LiteLLM case is the
proof: HTTP 200 with a broken database.
