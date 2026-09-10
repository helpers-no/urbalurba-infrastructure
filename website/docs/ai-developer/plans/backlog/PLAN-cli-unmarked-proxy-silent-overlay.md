# Plan: an unmarked proxy and no StatefulSet is the one revert that warns nothing

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Backlog

**Goal**: `uis deploy <svc>` cannot roll out an in-cluster workload on top of a
still-running proxy without saying so.

**Found**: 2026-09-10, tracing the blast radius of an unreadable
`external-services.yaml` for `ops` (`urb-agents#600`). The fail-open gate itself
is fixed in 1.6.50; this is the branch underneath it.

---

## The three cases, and the one with no output

When `deploy` decides a service is **not** external, it takes the
coming-back-from-external path in `service-deployment.sh`:

| what is on the cluster | what happens |
|---|---|
| a proxy carrying `uis.io/external-proxy=true` | deleted, the Service selector is restored, in-cluster deploys. Correct and loud |
| an unmarked proxy **and** a StatefulSet | warned about by name, not removed — *"a deploy must not delete a workload on a name match alone"*. Correct |
| 🔴 an unmarked proxy and **no** StatefulSet | **nothing.** In-cluster deploys beside a live relay |

The third row is the shape of a proxy created before the marker existed
(2026-08-30, `f6c14cd`) on an installation that has never run that service
in-cluster — which is precisely the installation most likely to be proxying it.

## Why it is worse than it looks

The proxy's own playbook **takes over the Service selector**, replacing it with
`app.kubernetes.io/name: <svc>`. The in-cluster workload's pods carry that same
label. So both back the Service at once and traffic splits between the real
data and a fresh empty instance — with no error anywhere, because from
Kubernetes' point of view nothing is wrong.

⚠️ The existing warning does not fire because its condition is
`[[ -n "$_sts_replicas" ]]` — it asks *"is there a StatefulSet to compare
against?"* rather than *"is something already serving this name?"*. **A guard
whose precondition is absent on exactly the installations it protects**, which
is the audit's shape one layer out.

## What needs deciding

1. **What identifies "a proxy" without the marker?** A Deployment sharing the
   service's name is the honest signal, and it is also what a legitimate
   in-cluster Deployment-based service looks like. Checking the pod spec for a
   relay container is more accurate and more brittle.
2. **Warn, or refuse?** Refusing blocks a real workflow — someone deliberately
   returning an old installation to in-cluster — on the reading that they might
   not mean it. A refusal with an explicit override is the middle, and every
   override is a thing to remember.
3. **Should the deploy check the Service's endpoints instead?** *"Something is
   already answering on this name"* is topology-independent and needs no
   marker, no name-matching and no guessing. It may make questions 1 and 2 moot.
   ⚠️ It also fires on a healthy redeploy, so it is only useful combined with
   "and we are about to deploy a different KIND of workload than what is there".

## Tasks

- [ ] 1.1 Decide question 3 first — if endpoint-based detection works it
      replaces the other two rather than adding to them
- [ ] 1.2 Decide 1 and 2 only if 3 does not
- [ ] 1.3 Implement, and make the message name what is currently serving
- [ ] 1.4 Version bump

## Acceptance

- ⚠️ **A test on a fixture with an unmarked proxy and NO StatefulSet.** The
  existing coverage has a StatefulSet in it, which is why this row was never
  seen — a fixture that includes the thing whose absence is the bug tests the
  case that already worked
- no path deploys in-cluster over a live relay without output

## The lesson this plan carries

The 1.6.6 fix for unmarked proxies made the scale-back unconditional and left
the *warning* conditional, on a variable that is empty in exactly the situation
the warning exists for. **A fix that corrects one branch's condition should be
asked whether the neighbouring branch shared it.**
