# Plan: `uis undeploy` exits 0 and keeps the data, and there is no `template uninstall`

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Backlog

**Goal**: after an undeploy, an operator must know exactly what still exists —
and a test of a clean install must be able to reach a clean machine.

**Found**: 2026-09-11 by `imac`, reported by `ops-dev` (`urb-agents#726`
finding 4). imac deleted the PVC by hand to make its clean-install criterion
honest.

---

## The two halves

**1. `undeploy` exits 0 and leaves the PersistentVolumeClaim.**

Keeping data on an undeploy is a defensible default — deleting a database
because someone removed a workload is the worse failure. 🔴 **The defect is that
it is silent.** "Undeployed" and "undeployed, and your data is still here" are
the same output, so:

- an operator believes the machine is clean when it is not;
- a redeploy silently adopts the old volume, including its schema and its
  migration state.

**2. There is no `uis template uninstall`.**

`template install` composes a multi-step install — database, roles, PostgREST,
Dagster code location, overlay entries. **Nothing reverses it.** Undoing an
application install is currently a hand-assembled sequence that the person doing
it has to derive from the install plan.

## 🔴 Why this matters beyond tidiness

⚠️ **Anyone testing an install path without knowing this is testing an upgrade.**

That is the sentence to keep. An acceptance run that believes it is proving
"installs from nothing" while a populated volume is mounted is proving something
else, and every number it produces — including install duration — belongs to a
different scenario. imac caught it; a less careful run would have reported a
clean-install pass.

## Shape of the fix

**Cheap half, do first:** `undeploy` reports what it kept, by name and size, and
prints the command that would remove it. No behaviour change, no risk. This
alone closes the "testing an upgrade" trap.

**Then:** `--purge` on `undeploy` to remove claims the service owns, refusing on
anything it cannot prove it created — the same discipline as the unmarked-proxy
case, where *"a deploy must not delete a workload on a name match alone"*.

**Then:** `uis template uninstall <app>`, derived from the same definition that
drove the install, with a dry-run that lists every object before touching one.

## Acceptance

- `uis undeploy <svc>` names every claim it kept and how to remove it.
- `--purge` removes only what UIS created, and says what it refused to touch.
- A second `deploy` after an `undeploy` states plainly that it is adopting
  existing data, not starting clean.
