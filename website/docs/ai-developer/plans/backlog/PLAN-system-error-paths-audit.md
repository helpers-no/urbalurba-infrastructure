# Plan: one deliberate pass over the error paths

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Backlog

**Goal**: Every path that runs only when something has already failed is
exercised at least once, so a failure reports its cause instead of being
swallowed by the mechanism meant to handle it.

**Proposed by**: imac, `urb-agents#344`, after finding the third instance in one
week. Its words: *"Each was invisible until something failed, and each made the
**next** failure harder to diagnose. Might be worth one deliberate pass over the
error paths rather than three more of these arriving one at a time."*

---

## The three, and what they have in common

| | Defect | Mechanism that defeated it |
|---|---|---|
| 1.6.9 | `installed_version()` returned empty while the image sat readable on disk, so `./uis version` said "no image on this machine yet" | `\|\|` binds to the **pipeline**, whose status is `tr`'s — the fallback was dead code |
| `#335` | Every `configure` failure in a template install was silent; a one-line usage error produced a 135-line log with no cause | `set -e` aborts on `x=$(cmd)` before `x_exit=$?` is read — the handler was unreachable |
| `#344` | `uis verify postgrest` failed with only `{"censored": ...}` on a healthy instance | `no_log: true` without `failed_when` — the task aborted and took the reason with it |

Three different mechanisms, one shape: **error handling that looks correct,
defeated by the semantics of the construct it is written in, in a branch nothing
executes until something else is already wrong.**

⚠️ **Each one made the next failure harder to diagnose**, which is the compounding
part and the reason this is worth a pass rather than three more fixes. The
`no_log` case cost the tester a manual reproduction to learn what a single line
of stderr would have said.

## Why a pass rather than waiting for the fourth

These are not caught by tests, and the reason is structural: a unit test asserts
what happens when things work. Every one of the three had passing tests around it
while it was broken. The only thing that found them was somebody running the tool
and hitting a failure — which means the discovery rate is bounded by how often
things go wrong in front of a human.

**One useful precedent**: the `set -e` fix landed with a test that greps every lib
for the pattern and fails if it returns. That works because the defect has a
*syntactic* signature. Not all three do, which is what makes this a pass and not
a lint.

## Scope

- `provision-host/uis/lib/*.sh` and `manage/*.sh` — command substitution, `||`
  after pipelines, `set -e` interaction. **The syntactic ones are already
  linted**; this pass is for what the grep cannot see
- `ansible/playbooks/*-test-*.yml` and `*-setup-*.yml` — `no_log` without
  `failed_when`, `failed_when: false` with nothing asserting the result
  afterwards, and `assert` messages that name a cause they cannot know
- the launcher `uis` — its fallbacks, which is where instance 1 lived

## Tasks

- [ ] 1.1 Enumerate every `no_log: true` task and record, per task, whether a
      failure there can reach a human with its cause. Fix or justify each
- [ ] 1.2 Enumerate every `failed_when: false` and confirm something downstream
      actually asserts on the result. A silenced failure that nobody checks is
      worse than an abort
- [ ] 1.3 Find `assert` messages that state a cause the task cannot establish —
      the postgrest B2 message blamed pod reachability for what was a permission
      error, until `#330` corrected it. A confidently wrong diagnosis costs more
      than none
- [ ] 1.4 Extend the existing lint where a signature exists; record where it
      cannot, and why, so the next reader does not assume the lint is complete
- [ ] 1.5 For the highest-value paths, **make them fail on purpose once** and read
      what a human gets. That is what found all three of these
- [ ] 1.6 Version bump if any shipped path changes

## Acceptance

- no `no_log: true` task can abort without its cause reaching stderr
- every `failed_when: false` has an asserting consumer, or a comment saying why
  the result is genuinely discardable
- at least one deliberate failure per verify playbook has been observed and its
  output recorded in the plan

## Out of scope

Removing `no_log`. It is there because those tasks carry `PGPASSWORD` and that
must not reach a log. The fix is always `failed_when` plus an assert that reads
`stderr` — the field with the diagnosis — rather than `cmd`, the field with the
secret.

## Note on who should do this

⚠️ **The pass is worth little without a cluster.** Task 1.5 is the one that found
every instance so far, and it cannot be done from a build host. The reading and
the lint work anywhere; the deliberate failures belong with the tester.
