---
title: PLAN — two Postgres defaults, so they are always set
sidebar_label: PLAN — Postgres defaults
---

# PLAN — two Postgres defaults, so they are always set

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

🔵 **Filed 2026-09-21 on Terje's explicit instruction, via ops (`urb-agents#1312`): "add it to its backlog and not do it now."** Nothing here is started or scheduled. Both settings are cheap now and expensive later, and neither is urgent.

**Goal**: two settings in the UIS PostgreSQL default, so that an installation has them without anyone remembering to apply them.

## Why they belong in the declaration rather than in a running database

Both come out of a capacity review of the `pg` instance on odin. The review's conclusion was that the instance is **healthy** — every pressure metric flat, backups clean, the binding constraint being two CPU cores rather than capacity. These are not fixes for a problem that is happening.

⚠️ **They are in the declaration because one of them cannot be added later without a restart, and the other is only useful before the incident it bounds.**

## 1. `pg_stat_statements` — enable by default

`shared_preload_libraries` is empty, and the chart does not set it. When a query gets slow there is then **no aggregate record of which query shape is responsible** — only individual slow lines in the log, which tell you that something was slow and not what.

- Requires a **restart** to take effect. That is precisely why it belongs in the declaration: adding it during an incident means restarting the database during the incident.
- The library already ships in the image; nothing new is installed.
- Set via `primary.extendedConfiguration` in `manifests/042-database-postgresql-config.yaml`.

## 2. `temp_file_limit` — bound the blast radius

Currently `-1`, unlimited. One bad analytical join can spill temp files until the data volume is full, and that volume is shared by every tenant on the instance. **A finite limit turns a database-wide outage into one failed query.**

⚠️ **Pick the number against the chart's `primary.persistence.size`, which defaults to `8Gi`** — not against what any particular host happens to have. A limit tuned to a large instance is no limit at all on a default install.

## ⓘ Not part of this plan: the default resources

```
requests: 512Mi / 250m      limits: 1Gi / 500m      persistence: 8Gi
```

Fine for the services UIS ships. **Far below what an analytical tenant needs** — one such tenant is 1.46 GB and 5.8 M rows across 108 tables on a host with 8 GB and two dedicated cores.

🔵 **Not a request to change the default.** The note worth writing down is that the default is not a starting point for that class of workload, and the install guide is probably where that belongs.

## 🔴 What this plan does NOT cover: the external instance

The same two settings apply to two systems with two owners, and conflating them means the change lands nowhere:

| | owner | mechanism |
|---|---|---|
| **the in-cluster default** | UIS — this plan | `042-database-postgresql-config.yaml` |
| **the external `pg` instance** | ops | an ansible-managed drop-in |

That instance is a hand-built LXC **deliberately outside Kubernetes**; UIS declares it *external* and the in-cluster object is a proxy to it. ⚠️ **UIS cannot set its configuration and should not try.**

## Success criteria

- [ ] A fresh install has `pg_stat_statements` loaded, verified by querying the view rather than by reading the values file
- [ ] `temp_file_limit` is finite, and the number is justified against the default `persistence.size` in a comment beside it
- [ ] A test asserts both, so neither can be dropped by a chart upgrade without the suite failing

## Related

- `urb-agents#1312` — the request, the capacity review it came from, and the ownership split
