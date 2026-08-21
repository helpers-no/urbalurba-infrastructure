# Plan: one constructor for a monitor, not two

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: `provision-host/uis/lib/monitors.py` builds a monitor object in **one**
place, so a per-monitor field added tomorrow cannot reach one kind of monitor and
silently miss the other.

**Last Updated**: 2026-08-21

---

## Dependencies

**Related**: [PLAN-service-uptime-kuma-005-ship-the-pipeline](./PLAN-service-uptime-kuma-005-ship-the-pipeline.md)
shipped `uis monitors`, which is where both constructors live. This plan does not
change what the pipeline does, only how the object is assembled.

**Prerequisites**: none.

**Priority**: Medium — nothing is broken today, but the next per-monitor field
repeats the failure, and the failure mode is silent.

---

## Problem Summary

`monitors.py` assembles a monitor object twice, from two sources, in two
independent pieces of code:

| Source | Built by | Keys set |
|---|---|---|
| Service probes, discovered from a cluster | `render_monitor()` (line 281) | 17 |
| `.uis.extend/monitors.yaml` entries | an explicit dict inside `build()` (line ~415) | 15 |

Both produce "a monitor". Neither knows about the other. A field added to one is
simply absent from the other, and nothing in the code, the tests or the output
says so.

### What that cost on 2026-08-21 (measured, not hypothetical)

`severity` shipped in **PR #252** and was added to `render_monitor()` only. Every
entry in `monitors.yaml` therefore fell back to the `"info"` default that
`attach_alerts()` applies (line 514).

Running `uis monitors apply` with that code, on the reference installation:

```
severity: 0 critical (page any hour), 22 info (daytime only)
alerting: 12 newly attached, 10 moved between severities, 10 already right
```

**Zero critical.** And the second line is the damaging part: it **moved ten
already-critical monitors onto the daytime-only channel** — the four backup
heartbeats, the k3s API, both Proxmox UIs, the vault, MinIO and pg. An overnight
failure in any of those would not have paged anyone.

After correcting the extend-file path, the same command on the same input:

```
severity: 12 critical (page any hour), 10 info (daytime only)
```

### Why it was not caught

1. **It looked like success.** Exit 0, no warning, and `10 moved between
   severities` reads like the tool doing its job. Nothing distinguishes "moved
   because you changed the declaration" from "moved because I lost it".
2. **The declaration was correct the whole time.** `monitors.yaml` said
   `severity: critical`; the parser dropped it. Reading the source of truth would
   not have revealed the bug.
3. **It surfaced by accident**, while adding the `temp-odin` / `temp-tor` heat
   monitors — which are declared critical precisely because overheating at 03:00
   must wake someone, and which landed on the daytime channel.

**The severity field is fixed. The shape that lost it is not.** This is the same
defect family this repo has hit repeatedly: a second registration point that new
things never reach — `VERIFY_SERVICES` registered in two of three places, secret
validation as a hardcoded allowlist, plan cross-references updated in one
direction. Each was fixed individually; the shape kept recurring.

---

## Phase 1: One constructor

### Tasks

- [ ] 1.1 Extract a single function that takes a normalised input and returns the
      monitor object — every key in one place, with defaults declared once
- [ ] 1.2 Both callers normalise their own input first (a probe artifact and a
      `monitors.yaml` entry differ in shape) and then call it. The *difference*
      between the sources stays at the edges; the object does not
- [ ] 1.3 Keep the `_`-prefixed convention for UIS bookkeeping (`_notify`,
      `_severity`), and keep stripping it before anything is written for AutoKuma
- [ ] 1.4 Preserve today's asymmetries deliberately or delete them deliberately.
      The two dicts differ by more than `severity`; each difference is either
      intentional or an older instance of this same bug, and the plan should say
      which

### Validation

`uis monitors render` produces byte-identical output for all 25 current
definitions before and after. This is the whole safety net for the refactor — the
reference installation has both kinds of monitor, so an identical render means
neither path changed.

---

## Phase 2: Make the next omission loud

A single constructor prevents *this* failure. It does not prevent a caller
forgetting to pass something.

### Tasks

- [ ] 2.1 Have `apply` report the severity split per source, so
      "0 critical from monitors.yaml" is visible rather than buried in a total
- [ ] 2.2 Consider failing when a declared key is not consumed by the
      constructor. A typo'd or unsupported field in `monitors.yaml` is currently
      ignored in silence — the same class of problem as the one this plan fixes

### Validation

Re-run the 2026-08-21 scenario against the pre-fix code path: the output must make
the loss obvious rather than reporting it as a successful move.

---

## Out of Scope

- What the severity levels *mean* or how the phone routes them — that is
  [PLAN-service-uptime-kuma-003-alerting](./PLAN-service-uptime-kuma-003-alerting.md).
- Auto-discovery of monitors from a second cluster, which
  [kuma-005](./PLAN-service-uptime-kuma-005-ship-the-pipeline.md) records as
  single-cluster only.

---

## Note

The `severity` bug itself is already fixed and merged; this plan is about the
structure that allowed it. Filing it because the finding otherwise lives only in
one session's context, and the next per-monitor field would rediscover it the
same way — by someone noticing an alert that should have fired and did not.
