# Plan: SemaphoreUI user-facing documentation

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: A lab owner who has just run `uis deploy semaphore` can find, on the
website, what the service is, what it can and cannot do, how to wire in their
first project, and the one upstream design choice (plaintext API tokens)
worth knowing before they rely on it.

**Investigation**: [INVESTIGATE-service-semaphore.md](../backlog/INVESTIGATE-service-semaphore.md)
— Part 4 named this as the second of two plans, alongside
[PLAN-service-semaphore-001-deploy.md](../active/PLAN-service-semaphore-001-deploy.md).

**Last Updated**: 2026-10-05

**Completed**: 2026-10-05

---

## Problem Summary

`PLAN-service-semaphore-001-deploy.md`'s own Phase 4 ran into this plan's
deliverable as a hard dependency rather than a follow-on: `services.json`'s
`SCRIPT_DOCS` field feeds Docusaurus's broken-link checker, and `npm run
build` **fails outright** if the page it points to does not exist. So the
docs page was written during PLAN-001's implementation, not after it — this
plan's content shipped in the same PR (#548) that shipped the service itself,
and this document exists to record that formally, record what the page
covers against the Investigation's original spec, and close out the
Investigation's Part 4 list rather than leave a named-but-never-written plan
sitting in `backlog/` pointing at work that already happened.

The Investigation's Part 4 described this plan's scope precisely:

> `website/docs/services/<category>/semaphore.md` describing what it is, the
> scope limitation from F8, how to add a first project/repository/credential
> ..., and the plaintext-token fact from F6 stated plainly rather than
> discovered the hard way.

That is a checklist. The rest of this document verifies the shipped page
against it, item by item, rather than re-describing it from scratch.

---

## Phase 1: Write the page

### Tasks

- [x] 1.1 Create `website/docs/services/management/semaphore.md`, following
  the shorter `argocd.md`/`pgadmin.md` template (summary table, What It Does,
  Deploy, Verify, Undeploy, Key Files, Troubleshooting, Learn More) rather
  than Uptime Kuma's much longer page — Semaphore's operational surface is
  far smaller (no monitors, no heartbeats, no alerting setup to document).
- [x] 1.2 Cover every item the Investigation's Part 4 named:

  | Required | Where on the page |
  |---|---|
  | What it is | "What It Does" — projects, repositories, templates, access keys, run history |
  | F8's scope limitation | "Running in-cluster is not a limitation" — states what it can reach (anything over SSH/HTTP) and the one thing it cannot (recovering its own pod's cluster) |
  | How to add a first project/repository/credential | "Adding your first project" — four concrete steps, explicitly tied back to the empty-by-default convention (`dagster-code-locations.yaml`) named in "A clean install has nothing configured" |
  | F6's plaintext-token fact | A `:::warning` callout stating tokens are stored as the bearer value itself, calling it upstream's own design, not a UIS defect |

  Also added beyond the Investigation's checklist, because the page would be
  incomplete without them: the admin-credentials table (which secret keys
  exist and what they inherit), the SQLite-not-Postgres rationale carried
  over from the Investigation's F3/Part 2, and a Troubleshooting section
  matching every other service page's shape.
- [x] 1.3 Fixed a relative-link break and confirmed the page renders:
  `npm run build` in `website/` passed with the page in place (verified
  during PLAN-001's implementation, not re-verified here since nothing about
  the page has changed since).

### Validation

```bash
cd website && npm run build
```

Passed as part of PR #548 — `services.json`'s `semaphore` entry's `docs` link
resolves, so the broken-link checker that made this page mandatory is itself
the validation.

---

## Acceptance Criteria

- [x] `website/docs/services/management/semaphore.md` exists and covers all
  four items the Investigation named (see table above)
- [x] `npm run build` passes with the page in place
- [x] No real hostnames, IPs, or reference-instance project/repository names
  appear on the page (same constraint as the Investigation and PLAN-001)
- [x] This plan is in `completed/`

---

## Files to Modify

- `website/docs/services/management/semaphore.md` — shipped in PR #548, not
  this PR. This document is the retrospective record of that work, not a
  second round of changes to the page.

---

## Implementation Notes

- **Why this plan shipped before it was written.** The normal flow is
  `backlog/` → `active/` → `completed/`, written before the work starts. This
  one inverted that because the dependency ran the other way: PLAN-001
  couldn't pass its own Acceptance Criteria (`npm run build` passing) without
  this page existing first. Writing this document after the fact is the
  honest record of what happened, not a re-enactment of a planning step that
  would have been theater at this point — see PLAN-001's own Implementation
  Notes for where it says so explicitly.
- **Nothing here is scheduled for later.** Unlike `PLAN-tools-docs.md`
  (hand-maintained, revisit if drift recurs), there's no deferred piece of
  this plan — the Investigation named exactly one page with four required
  contents, and all four shipped.
