---
title: PLAN — a undeploy --purge verb for the data a service leaves behind
sidebar_label: PLAN — undeploy --purge
---

# Plan: `uis undeploy <service> --purge`

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

🔵 Filed 2026-09-29 at imac's request (`urb-agents#1725`), after it followed the documented remedy exactly and could not use it.

## The problem, measured

`uis undeploy authentik` deliberately leaves the database and role — [retain-by-default is right](./INVESTIGATE-provisioning-declaration.md), because UIS [cannot back up what it deploys](./INVESTIGATE-system-backup-and-scheduling.md), so a removal that destroys data has no undo.

It prints the remedy. The remedy could not be run:

| | |
|---|---|
| a bare relative path | `ansible-playbook playbooks/utility/u09-…yml` — never says it must run **inside** `uis-provision-host`, and from `./uis` it cannot be reached |
| an interactive `pause` | with no TTY it produced **`❌ Deletion aborted by user`, exit 2** — and nobody aborted anything |

🔴 **The second is the worse half: the message blamed the operator for the automation's own limitation.** That is the defect class this repository spends most of its time on, sitting inside the remedy the product recommends.

⚠️ **Partly fixed in 1.6.173**: `-e confirm=yes` is now a non-interactive path, the abort message says what actually happened, and the printed remedy names the container path and the flag. **So it is runnable now** — but by dropping into a container and calling ansible directly, which is the inner mechanism rather than the product's surface.

## What is missing

Every other lifecycle action is a `uis` verb. Removing the data a service left is not, and it is the one action where reaching for the inner mechanism is most dangerous: a mistyped playbook name or operation there is irreversible.

**Proposed:** `uis undeploy <service> --purge`, which runs the service's own delete path, and refuses without an explicit confirmation when there is no terminal.

- [ ] 1.1 A `--purge` flag on `undeploy`, dispatching to the service's delete mechanism where one exists
- [ ] 1.2 **Refuse, naming what would be destroyed**, when neither a TTY nor an explicit confirm is present — never assume consent from silence
- [ ] 1.3 🔴 **Refuse for a service with no delete path** rather than reporting success. `configure --purge` for postgresql was accepted and ignored for months; the same flag must not acquire the same defect here
- [ ] 1.4 Name it in `undeploy`'s output in place of the ansible command
- [ ] 1.5 A test asserting every service `--purge` accepts has a delete path, in both directions — the shape that caught the `SCRIPT_CONFIGURABLE` drift

## What this is not

Not a change to the retain-by-default decision. Purging stays something the operator asks for by name, and 1.2 keeps it from happening by accident.

⚠️ And not a reason to make `undeploy` destructive. The value is that the *documented* way to remove data is a product verb with a guard, rather than a container shell and a raw playbook.
