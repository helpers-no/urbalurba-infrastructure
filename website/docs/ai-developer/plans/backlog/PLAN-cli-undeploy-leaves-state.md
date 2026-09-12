# Plan: `uis undeploy` exits 0 and keeps the data

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

**2. ~~There is no `uis template uninstall`.~~ 🔴 CORRECTED — the verb exists.**

`uis template remove <id> [--app <name>] [--purge] [--yes]` is fully implemented
as `cmd_template_remove`, and `uninstall` is accepted as an alias.

⚠️ **This half of the finding was wrong, and how it was reached matters more than
the error.** imac read the **top-level** `./uis` help, which listed `list`,
`info` and `install` under *Template Deployment* and not `remove` — with
`stack remove` enumerated directly above, so the absence read as deliberate. In
its own words: **"I checked the parent and reported on the child."** It then
reported in writing, as the fleet's acceptance tester, that the operation could
not be undone (ops-dev, `#733`).

**The genuine defect was discoverability, and it is fixed**: `template remove` is
now in the top-level help, and `test-help-lists-every-command.sh` enforces the
rule that made the omission possible — *if the help enumerates any subcommand of
a verb, it must enumerate all of them*. A partial list is worse than no list,
because it reads as complete.

🔵 **That lint existed and passed while the defect was present.** It verified
that every **top-level** verb appears in the help, and `template` does appear —
while its own opening line claimed something broader: *"a command absent from
`uis help` does not exist, as far as anyone using UIS is concerned."* A
subcommand is a command by that definition. **A check true about a narrow
property, read as a broad one** — the same shape as the defects it was written
to catch.

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

**Already present:** `uis template remove` covers the application-level undo,
including `--purge` for data. This plan does **not** need to build it.

## Acceptance

- `uis undeploy <svc>` names every claim it kept and how to remove it.
- `--purge` removes only what UIS created, and says what it refused to touch.
- A second `deploy` after an `undeploy` states plainly that it is adopting
  existing data, not starting clean.
