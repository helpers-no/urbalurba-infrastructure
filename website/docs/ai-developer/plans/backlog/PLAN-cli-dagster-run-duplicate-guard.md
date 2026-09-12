# Plan: `uis dagster run` launches duplicates silently

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Backlog

**Goal**: launching a job that is already running must be a deliberate act, not
the default.

**Found**: 2026-09-11 by `imac`, reported by `ops-dev` (`urb-agents#726`
finding 3), while testing `--wait` against an already-running job.

---

## What happened, and why it looked fine

A second `brreg_bootstrap` was refused in 14 seconds — **by atlas, not by UIS.**
atlas holds its own lock in `raw.ingest_runs`.

🔴 **UIS contributed nothing to that outcome.** A tenant without such a lock gets
two concurrent loads of the same data and no warning from the verb that started
them.

⚠️ This is the shape that makes a defect hard to see: the system behaved
correctly, so the missing guard produced no symptom. It was found by someone
testing the case deliberately, and the safety belonged to the tenant.

## Why the default should be to refuse

`uis dagster run` exists because an install would otherwise wait a day for its
data — so it is used **at install time, by an operator, often twice** when the
first attempt appears stuck. `#726` records exactly that pressure: a
`brreg_bootstrap` takes 492 s on first load and 867 s on a populated table, and
`--timeout` was under-waiting (fixed in 1.6.60). **"It looked stuck so I ran it
again" is the expected human action, not an unusual one.**

## Shape of the fix

Before the launch mutation, ask Dagster for runs of this job in a non-terminal
state (`QUEUED`, `NOT_STARTED`, `STARTING`, `STARTED`) and refuse if any exist:

- the refusal must **name the existing run id and how long it has been running**,
  because the next question is always "is the other one healthy or wedged";
- `--force` (or `--allow-concurrent`) to proceed anyway — some jobs are
  partitioned and genuinely concurrent;
- ⚠️ **"could not ask" is not "nothing is running."** If the query fails, say so
  and refuse, rather than launching on an unanswered question. Same rule as the
  external-services gate in 1.6.50.

## Acceptance

- A second `uis dagster run <job>` while one is in flight refuses, names the
  run id and its age, and exits non-zero.
- `--force` launches anyway and says that it did.
- A failed status query refuses and is distinguishable from a clean "nothing
  running".
- Exercised against a live Dagster — the guard and the thing it guards must not
  be written in the same breath with only the guarded path tested.
