# `uis deploy` reports one exit code for two different outcomes

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: An operator or a script can tell "the topology change failed" apart from "the topology
change worked and the service deploy that followed it did not".

**Last Updated**: 2026-08-30

**Priority**: Medium — nothing is broken today, and it becomes a real hazard the moment
`uis deploy` is used in automation.

**Origin**: found by the independent tester while grading the selector-capture ordering fix
(2026-08-30). Not a defect in that branch; it is older and more general.

## Problem Summary

`uis deploy <service>` on an installation that has just had an external declaration **removed** does
two separable things, in order:

1. **The topology change** — remove the proxy Deployment, restore the Service selector from its
   annotation, scale the in-cluster workload back up.
2. **The service deploy** — run the service's own setup playbook to bring the in-cluster service up.

Only one exit code comes out, and it describes step 2.

The tester saw **the same revert produce exit 0 and exit 3 on the same cluster minutes apart**. Both
times step 1 succeeded; the difference was in the Helm step inside step 2, which looked transient.
A caller reading exit 3 would conclude the revert failed, when the topology had in fact already
returned to in-cluster.

This is the same family as a defect already fixed once in this area: the report task used to raise
`'_external_port' is undefined` and exit 3 **after** the cluster was fully swapped, telling the
operator the deploy failed while it had succeeded. That instance was fixed; the general shape was
not.

## Why it is worth investigating rather than just patching

The obvious patch — make step 1 report separately — raises questions that want deciding, not
guessing:

- **What should the exit code mean?** Today it means "the last thing I ran succeeded". Arguably it
  should mean "the cluster is in the state you asked for", which is a different claim.
- **Is a partial success a success?** Reverting to in-cluster and then failing to deploy the service
  leaves a Service selecting a workload that may not exist yet. That is recoverable and is not the
  same as "nothing happened".
- **Retry safety.** An operator who reads exit 3 and re-runs is running step 1 again. It is
  idempotent today — the annotation is gone, so the "no remembered selector" branch takes over — but
  that is worth confirming rather than assuming.
- **Does `deploy` even own step 1?** It might belong in its own verb, so that changing topology and
  deploying a service are separately observable. That is a CLI design question.

## What is already known

- Step 1's operations are logged individually, so the information exists in the output — it is only
  the *exit code* that collapses them.
- `uis verify <service>` can already distinguish the topologies and will say which one is live, so
  the recovery path after an ambiguous exit is short.
- The flaky Helm failure the tester hit is environmental (minio had never been installed on that
  box) and is **not** the thing to fix here. It is only what made the ambiguity visible.

## Open Questions

1. Should the topology change and the service deploy be separate commands, separate exit codes, or a
   single command with a richer summary?
2. What should a caller in automation branch on — exit code, a machine-readable summary, or
   `uis verify` afterwards?
3. Is step 1 genuinely idempotent on a re-run after a step-2 failure? Needs a test, not an argument.

## Suggested Next Step

A tester round that deliberately fails step 2 on a cluster where step 1 succeeds, and records what
an operator can and cannot conclude from the output as it stands today. That measurement should come
before any design.
