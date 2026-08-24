---
title: "Service-category taxonomy — mixed axes, and where orchestrators belong"
status: backlog
type: INVESTIGATE
area: system
severity: low
created: 2026-08-24
---

# Service-category taxonomy — mixed axes, and where orchestrators belong

**Status**: Backlog, **deferred** — Terje, 2026-08-24: *"look into later."*
**Priority**: Low. Page tidiness, not a functional gap.
**Triggered by**: Dagster → `ANALYTICS` and Temporal → `INTEGRATION` looking
arbitrary next to each other on the services page.
**Boundaries**: taxonomy is assist's to propose; **Terje approves**.

## The observation

`CATEGORY_ORDER` mixes **three** classification axes:

| Axis | Categories |
|---|---|
| by component **type** | `DATABASES`, `STORAGE`, `APPLICATIONS`, `NETWORKING` |
| by **function** | `OBSERVABILITY`, `AUTOMATION`, `MANAGEMENT`, `INTEGRATION`, `IDENTITY` |
| by **domain** | `AI`, `ANALYTICS` |

Because of that, the two orchestrators land on *different axes*: Dagster by
**domain**, Temporal by **function**. Neither placement is wrong on its own, and
the split hides the one thing a user actually needs to know — that they are both
orchestrators, of different shapes.

## Current distribution (2026-08-24)

Measured from the generated `services.json`, 37 services:

| Category | n | Axis |
|---|---|---|
| `OBSERVABILITY` | 7 | function |
| `DATABASES` | 6 | type |
| `MANAGEMENT` | 6 | function |
| `ANALYTICS` | 5 | domain |
| `INTEGRATION` | 5 | function |
| `AI` | 2 | domain |
| `AUTOMATION` | 2 | function |
| `IDENTITY` | 1 | function |
| `APPLICATIONS` | 1 | type |
| `NETWORKING` | 1 | type |
| `STORAGE` | 1 | type |

Worth noting before redesigning anything: **four categories hold a single
service**. Whatever axis is chosen, the more pressing readability problem may be
that a third of the categories are nearly empty, not which axis they use.

## The questions

1. **Should a category describe what a component IS, or what you USE it for?**
   Pick one axis and the whole page becomes predictable. `DATABASES` already sets
   a by-type precedent: PostgreSQL lives there regardless of whether a given
   installation uses it for analytics or integration.
2. **Should there be an `ORCHESTRATION` category** (by-type, like `DATABASES`)
   holding **both** Temporal and Dagster, each described by shape — durable
   processes vs data assets?
   This would make the existing platform rule *browsable*: the category page
   answers "why do we have two orchestrators?" instead of the answer living only
   in the Dagster docs page, which someone looking at Temporal never opens.
3. **Do the single-service categories earn their place**, or should some merge?
4. **What does a service author consult** when adding a service? Right now the
   answer is "read the existing list and guess" — whatever axis is chosen, the
   rule needs writing down where `adding-a-service.md` will send them.

## ops' lean, recorded as input rather than decision

Add `ORCHESTRATION`: consistent with the `DATABASES` precedent, and it surfaces
the one-orchestrator-per-shape rule. But the axis-consistency question above is
the bigger win; the category is one instance of it.

## What a new category actually costs

Measured, not estimated — adding `AUTOMATION` for browserless touched **44 files**
in one commit (`33f1e3d`). Most of that was the service itself, but the
category-specific work was:

- `provision-host/uis/lib/categories.sh` — `_CATEGORY_DATA` **and** `CATEGORY_ORDER`
- `website/docs/services/<category>/_category_.json` + `index.md`
- `website/sidebars.ts`
- a category logo in `website/static/img/categories/`
- `CLAUDE.md` and `AGENTS.md` (the manifest-numbering table)
- `website/docs/contributors/rules/kubernetes-deployment.md`
- regenerating `services.json` / `categories.json`

**Moving an existing service between categories is the expensive part**, and this
investigation implies moving at least Temporal:

- its docs page moves directory, so **every inbound link breaks** — and, as the
  browserless plan move showed, links break in *both* directions
- `SCRIPT_DOCS` in the service definition changes, so the generated
  `services.json` entry changes
- the published URL changes, which is a real break for anything linking in from
  outside the repo
- category positions renumber (they must match `CATEGORY_ORDER`; a duplicate
  position was found and fixed during the AUTOMATION work)

A redirect strategy for moved doc pages is therefore part of this investigation,
not an afterthought.

## Why this is genuinely low priority

Nothing is broken. Every service is findable via search and the sidebar, and the
orchestrator distinction *is* documented — just in the Dagster page rather than
in a category. The cost is a reader forming a wrong mental model of how the
platform is organised, which is real but cheap compared to any of the open
functional work.

## Related

- The two-orchestrator rule lives in
  [Dagster](../../../services/analytics/dagster.md) — the content that an
  `ORCHESTRATION` category page would surface
- [Adding a Service](../../../contributors/guides/adding-a-service.md) — where the
  chosen rule would need to be stated
