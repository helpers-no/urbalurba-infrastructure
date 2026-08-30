# A workflow's `paths:` filter and what the job actually depends on drift apart, silently

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: Decide how a workflow's declared `paths:` can be kept honest against what its job really
reads, so this stops being found one instance at a time by the tester.

**Last Updated**: 2026-08-30

**Priority**: Medium. Nothing is broken right now — all four known instances are fixed. It earns an
investigation because the *class* has recurred four times and been fixed four times without ever
being addressed.

## Problem Summary

A `paths:` filter is a claim: *these are the files that make this job's answer change.* When the
claim is narrower than the truth, the job **does not run**, and a not-run job is indistinguishable
from a passing one in every UI that matters. No red mark, no annotation, no failure — just silence.

Four instances, all in this repository, none found by the author:

| | Workflow | What the filter missed | Consequence | Found by |
|---|---|---|---|---|
| 1 | `test-uis.yml` | `ansible/**` | A playbook change ran **no tests at all** — how a hardcoded postgres pod name shipped and stayed green | tester |
| 2 | `docs.yml` | `version.txt` | The navbar badge read `version.txt` at build time, so a version bump never rebuilt the site and the badge sat a release behind — showed v1.6.0 while `main` was v1.6.1 | tester |
| 3 | `generate-uis-docs.yml` | **its own workflow file** | The 2026-08-30 runtime bump edited this workflow and the workflow did not notice, so its bumped action pins merged and never executed | tester |
| 4 | `test-uis.yml` | **its own workflow file**, in *both* triggers | Same as 3. **Found by audit while fixing 3**, not by anyone hitting it | audit |

Instance 4 is the one that turns this from a habit into a finding: **a check that takes under a
second found a live instance nobody had hit yet.** Two of the four workflows were wrong at the
moment someone finally looked.

⚠️ `docs.yml` already carries a comment recording that this was the *second* time. The scar tissue
exists; the check does not.

## Two problems, not one

They want separating, because one is trivially checkable and the other is not.

**A. Does a workflow list its own file?** Purely structural. A workflow that cannot be triggered by
editing itself cannot test its own change, and the only remedy is a human who does not know they are
needed. Terje's framing, 2026-08-30: **CI should be automatic.** This is decidable by reading the
YAML alone, needs no knowledge of what the job does, and would have caught instances 3 and 4.

**B. Does the filter cover what the job actually reads?** Instances 1 and 2 were dependencies
*outside* the filtered tree — a playbook directory, and a version file read at build time. There is
no general way to know what a job reads without running it, so any check here is a heuristic. Some
tractable sub-cases:

- A step that reads a path (`cat version.txt`, `bash provision-host/uis/tests/run-tests.sh`) which
  no `paths:` entry covers.
- A workflow that runs a script, where the *script's* inputs are outside the filter — instance 1's
  exact shape, since the static suite scans `ansible/`.
- Comparing what a job touched during a real run against the filter, after the fact.

## What is already known

The static test suite in this repo has the right shape for problem A, and the precedent is
deliberate. `test-external-proxy-contract.sh` keys off **the templates on disk** rather than a list
of names, so adding a proxy template starts guarding that service with no edit to the test. The same
trick applies: enumerate `.github/workflows/*.yml`, assert each lists its own path in every trigger
that has a `paths:` block. That guard cannot go stale as workflows are added.

Two constraints that suite established and that any new guard should inherit:

- **It must carry a self-check.** A matcher that silently stops matching reports PASS forever.
- **An empty subject list must fail, not pass.** Finding zero workflows is a broken gate, not a
  clean repo.

## Open Questions

1. Is problem A worth a guard on its own, or only alongside some progress on B? A is cheap and
   complete; B is open-ended. Shipping A alone risks declaring the class closed when it is not.
2. Should a `paths:` filter exist at all on the cheap workflows? `test-uis.yml` runs a static suite
   in about a minute. A filter saves little and has now been wrong twice on that one file. **Running
   always is a legitimate answer to a filter that keeps being wrong** — and it is not available to
   `build-uis-container.yml`, which is a 13–20 minute multi-arch build.
3. For B, is the tractable version "compare against what a real run touched" rather than static
   analysis? That needs run data nobody currently collects.
4. Does this belong with the other CI-hygiene work, or stand alone? It is cross-cutting: every
   instance was in a different workflow.

## Suggested Next Step

Implement **A** as a static test, with the self-check and empty-list rules above, and re-run the
audit that found instance 4 as its first red case. Leave **B** in this file until someone has a
mechanism they believe in — a heuristic that produces false positives on a correctness check trains
people to route around it, which is the failure mode this repository has already recorded elsewhere.

## Related

- [[INVESTIGATE-system-launcher-image-version-drift]] — the same "two things that must agree, and
  nothing checks that they do" shape, one layer down
