# Plan: advertise only the `configure` handlers that exist

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Backlog

**Goal**: `SCRIPT_CONFIGURABLE="true"` appears only on services that actually have a
`configure` handler, so `uis configure <service>` never advertises a capability that
fails at the point of use.

**Decided**: 2026-09-07 by Terje — item 3 of the sequence in
[Rules for Deploying Applications](../../../contributors/rules/application-deployment.md).

**Related**: [ANALYSIS-nais-uis](../backlog/ANALYSIS-nais-uis.md) §4 item 4 ("finish or retract
`SCRIPT_CONFIGURABLE`", effort S) — this is the *retract* half, chosen deliberately.

---

## The problem, measured

Eight services declare the flag; **two have handlers**:

```
declared : elasticsearch mysql mongodb qdrant postgresql redis authentik postgrest
handlers : postgresql postgrest        (provision-host/uis/lib/configure-*.sh)
the rest : "Handler not yet implemented."   (provision-host/uis/lib/configure.sh:234)
```

The two that work are exactly the two the first real application needs. So the
provisioning half of the application-deployment rule works for that tenant and would
fail for the next one — **and it fails late**, after the user has been told the service
is configurable.

This is the same defect class that cost the first tenant two of its four install steps,
pointed the other way: there, a real capability was documented as absent; here, an
absent capability is advertised as real. Both are resolved by making the declaration
match the code.

## Decision

**Retract the six. Build no handlers now.**

Considered and rejected: implementing redis and mongodb first. Terje's call, 2026-09-07 —
neither is needed yet, and building on speculation is how the six stubs happened.

⚠️ **Retracted is not cancelled.** Re-declaring is a one-line change on the day a
handler lands, and the handler is the thing that earns the flag.

## Tasks

- [x] 1.1 Remove `SCRIPT_CONFIGURABLE="true"` from the six service files:
      `elasticsearch`, `mysql`, `mongodb`, `qdrant`, `redis`, `authentik`
- [x] 1.2 Regenerate `website/src/data/services.json` and confirm the flag disappears
      for exactly those six and remains for `postgresql` and `postgrest`
- [x] 1.3 Make `configure.sh` reject an unconfigurable service *by its metadata* rather
      than by falling through to a missing handler — the error should say "service X is
      not configurable" and list what is, not "handler not yet implemented", which reads
      as a promise
- [x] 1.4 Add the rule to [adding-a-service.md](../../../contributors/guides/adding-a-service.md):
      declare `SCRIPT_CONFIGURABLE` **only** when a handler exists
- [x] 1.5 Add a unit test asserting every service declaring the flag has a matching
      `configure-<id>.sh` — so the drift cannot come back silently

## Acceptance

- `uis configure redis --app x` fails with "redis is not configurable" and names the
  services that are
- `grep -l 'SCRIPT_CONFIGURABLE="true"'` returns exactly two files
- The new unit test fails if either is untrue

## Out of scope

Implementing any handler. That is a separate plan per service, and each one needs its own
answer to "what does configuring this service for one app even mean" — which for Redis
(a shared keyspace? a numbered DB? an ACL user?) is a design question, not a coding task.
That question is precisely why speculative flags are worse than no flags.

---

## Completed 2026-09-29 — 1.6.169

Terje's decision, after the consequences were measured in `urb-agents#1710`:
**all six, including authentik.**

The question that decided it was *"will authentik deploy stop working?"* — answered
empirically rather than by inspection: flipping the flag in a copy of
`service-authentik.sh` and diffing every `SCRIPT_*` variable the deploy path consumes
showed **one line changed and nothing else**. `SCRIPT_PLAYBOOK`, `SCRIPT_NAMESPACE`,
`SCRIPT_CHECK_COMMAND`, `SCRIPT_REQUIRES` and `SCRIPT_REMOVE_PLAYBOOK` are byte-identical,
and a sweep of 534 files found **zero references to the flag in any deploy path**.

### One task the plan did not have

🔴 `configure.sh` printed **`uis configure redis --app volunteer-app --json`** as an
example in the usage shown when the syntax is wrong — so retracting redis without
touching it would have handed the operator a second failing command at the moment they
were already confused. Fixed, and `test-configurable-has-a-handler.sh` now asserts that
every service named in those examples is configurable.

### What the six became

`SCRIPT_CONFIGURABLE="false"` with a comment naming the reason, rather than the field
being deleted — matching `oauth2-proxy`, which already spelled it that way. Absence and
`"false"` behave identically at the gate; an explicit `"false"` says *considered and
declined* where an absent field says *nobody filled this in*.
