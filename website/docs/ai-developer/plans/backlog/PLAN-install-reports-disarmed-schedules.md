---
title: PLAN — an install should say when it left a schedule disarmed
sidebar_label: PLAN — disarmed schedules
---

# PLAN — an install should say when it left a schedule disarmed

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

🔵 Filed 2026-09-23 from `urb-agents#1439`. **The cheap half already shipped** in 1.6.148: the install now warns that an upgrade can introduce a schedule that ships STOPPED. This is the version that *counts* instead of warning.

## The measurement

An install added a seventh cron to an application. Afterwards:

```
6 declared / 5 RUNNING / 1 STOPPED      <- the new one, disarmed
```

**Nothing said so.** The 06:00 run did not happen, and no surface reported its absence. The operator found it by diffing the instigator list by hand.

## Why the disarmed state is right and the silence is not

Shipping a schedule stopped is **correct** — an install must not begin contacting external services on its own, and `--start` refusing without `--yes` on a non-TTY is the same principle. Neither is a defect and neither should change.

🔴 **What is wrong is that the surprising case and the ordinary case look identical.** On a fresh install *everything* is stopped and the operator knows it. On an upgrade, one new schedule is stopped among five running ones — and the host's posture was already "switched on", so there is no reason to look.

## The blocker, and why it is not a one-liner

UIS cannot tell those two cases apart without asking Dagster for the instigator states.

🔵 **That query already exists** as `361-dagster-automation.yml`, which reduces schedules and sensors to names and states and splits them. ⚠️ **It should be reused rather than reimplemented** — two implementations of one query in two languages is the drift hazard that shipped an invented label in 1.6.130.

But `template.sh` invokes no playbooks today; it talks to the cluster with `kubectl` directly. Adding the first playbook call from there is a coupling decision, not a line of code.

## Shape

- [ ] After an install that ships a Dagster code location, run the automation report **non-fatally** — a Dagster that cannot be reached must not fail an install that otherwise succeeded
- [ ] Report the counts, and say plainly when any instigator is STOPPED
- [ ] ⚠️ Distinguish **"all stopped, as a fresh install leaves them"** from **"some running, one not"** — the second is the finding; the first is the documented default and saying it loudly would train people to skip the message
- [ ] A test asserts the second case produces output, because that is the one nobody sees today

## Related

- `urb-agents#1439` — the measurement, and the argument that the refusal itself is good design
