# Plan: Finish Alloy against the adding-a-service guide

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog — implemented in the working tree, awaiting review

**Goal**: Bring the Alloy service into actual compliance with
[adding-a-service.md](../../../contributors/guides/adding-a-service.md), so its
E2E tests are reachable, it works on production as well as Rancher Desktop, and
it appears on the website like every other service.

**Last Updated**: 2026-08-11

---

## Dependencies

**Investigation**: [INVESTIGATE-system-verification-playbooks-usage](./INVESTIGATE-system-verification-playbooks-usage.md)
— defect A1 below is exactly the failure mode that investigation predicted.

**Prerequisites**: none — Alloy is already deployed and collecting.

**Priority**: High — three of the four defects are silent. Nothing failed loudly,
which is why they shipped.

---

## Problem Summary

Commit `66642ad` ("Alloy: make it a real UIS service, following the guide") went
step by step through the guide and got most of it right: service definition,
setup/remove playbooks, Helm repo registration, `enabled-services.conf.default`,
stack membership, a docs page, and a verify playbook that asserts on what
*arrived* rather than on pod status.

Four things were missed, and each fails quietly.

### A1 — The verify playbook was unreachable by any command

Step 5b names two registration points. `VERIFY_SERVICES` was updated; the
`uis-cli.sh` dispatch was not. There are in fact **two** dispatch sites, and
`VERIFY_SERVICES` stores the form registered by neither:

| Invocation | Dispatch site |
|---|---|
| `uis verify <id>` | the `case` in `cmd_verify()` |
| `uis <id> verify` | the main command `case` |

Measured before the fix:

```
uis alloy verify        -> ✗ Unknown command: alloy
uis verify alloy        -> ✗ (absent from the verify list)
```

`031-test-alloy.yml` was therefore dead code, and `test-all` — which uses the
`uis alloy verify` form — would have reported a failure for it. The docs page
had already been telling users to run `uis verify alloy`.

### A2 — The verify playbook was pinned to `rancher-desktop`

`031-test-alloy.yml` is the **only** verify playbook in the repo that sets
`context: "{{ _target }}"`, defaulting to `rancher-desktop`. `deploy` gets its
target from `cluster-config.sh` via `service-deployment.sh`; nothing did that for
verify, so on the production host (`TARGET_HOST="asgard"`) it aborted with
`Invalid kube-config file. Expected object with name rancher-desktop`.

This is precisely the dev/prod parity the platform promises.

### A3 — No website metadata

Alloy was the only service in `observability/` with none of `SCRIPT_ABSTRACT`,
`SCRIPT_SUMMARY`, `SCRIPT_TAGS`, `SCRIPT_LOGO`, `SCRIPT_WEBSITE`, `SCRIPT_DOCS`
or `SCRIPT_OWNER`. The guide's wording on these is "Fill them in."

### A4 — Generated website data was never regenerated

`services.json` and `stacks.json` are **tracked in git** and generated from the
service definitions by `uis-docs.sh`. Neither was regenerated, so despite the
docs page, the sidebar entry and the stack membership all being added, the
website's own data had **no alloy entry at all** and its observability stack
still listed five services.

---

## Phase 1: Make the verify command reachable

### Tasks

- [x] 1.1 Add `cmd_alloy_verify()` calling `031-test-alloy.yml`
- [x] 1.2 Register the `alloy)` arm in `cmd_verify()` (`uis verify alloy`)
- [x] 1.3 Register the `alloy)` arm in the main dispatch (`uis alloy verify`) —
      the form `VERIFY_SERVICES` stores, commented so it is not dropped again
- [x] 1.4 Add Alloy to the top-level help and both verify usage lists
- [x] 1.5 While in the same block: add the missing `uptime-kuma` line to the
      second usage list

### Validation

Both invocation forms run the playbook.

---

## Phase 2: Make verify target the actual cluster

### Tasks

- [x] 2.1 Resolve `target_host` from `cluster-config.sh` in `cmd_alloy_verify`,
      the same way `service-deployment.sh` does for deploy, and pass it as an
      extra-var

### Validation

Passes on the production reference installation, whose context is `asgard`:

```
✅ Alloy: 1 pod(s) Running
✅ Logs are reaching Loki - real namespaces present
✅ No high-cardinality `instance` label
PLAY RECAP: ok=4  changed=0  unreachable=0  failed=0
```

Confirmed via **both** `uis alloy verify` and `uis verify alloy`.

---

## Phase 3: Website metadata and generated data

### Tasks

- [x] 3.1 Add the full Website Metadata block to `service-alloy.sh`, matching the
      sibling observability services, and restore the section headers the other
      definitions use
- [x] 3.2 Add `website/static/img/services/alloy-logo.svg` (official Grafana
      Alloy mark), mirrored into `src/` per the existing convention
- [x] 3.3 Add an `alloy)` component note in `stacks.sh` — it was rendering as an
      empty string next to five described siblings
- [x] 3.4 Regenerate `services.json` and `stacks.json` with `uis-docs.sh`

### Validation

- Alloy present in `services.json` with logo, abstract, tags and summary
- Observability stack lists six components, Alloy at position 4 with its note
- All 34 services' logo and docs references resolve to files that exist

---

## Known Gap

`npm run build` (guide step 11) was **not** run — Node is not installed on the
workstation or in the provision-host container. The link check it performs was
approximated by verifying every `logo` and `docs` reference in `services.json`
resolves on disk, plus the sidebar and category-index entries. A real build
should still be run before merge.

---

## Out of Scope

`uptime-kuma` had the same A1 defect. Now fixed and tested under
[PLAN-cli-verify-registration-fix](./PLAN-cli-verify-registration-fix.md), which
also covers correcting the guide — two services missing the same step points at
the instructions, not the contributors.
