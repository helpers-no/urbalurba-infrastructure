# Plan: Registering a verify command is a three-place change

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog — Phase 1 implemented and verified, Phase 2 open

**Goal**: Make every registered verify playbook reachable from both invocation
forms, and correct the guide so the next service does not repeat the omission.

**Last Updated**: 2026-08-11

---

## Dependencies

**Investigation**: [INVESTIGATE-system-verification-playbooks-usage](./INVESTIGATE-system-verification-playbooks-usage.md)
— this plan is one of the two concrete findings that promoted it to Tier 1.

**Related**: [PLAN-service-alloy-verify-and-metadata-fix](./PLAN-service-alloy-verify-and-metadata-fix.md)
— same defect, found first on Alloy.

**Priority**: Medium — it silently disables E2E tests, which is exactly the class
of failure `test-all` exists to prevent.

---

## Problem Summary

[adding-a-service.md](../../../contributors/guides/adding-a-service.md) Step 5b
says registration is "two files to update". It is actually **three places**, and
the guide names only two of them:

| # | Place | Enables |
|---|---|---|
| 1 | `VERIFY_SERVICES` in `integration-testing.sh` | `test-all` knows the service has a verify step |
| 2 | the `case` in `cmd_verify()` | `uis verify <id>` |
| 3 | the main command `case` | `uis <id> verify` |

`VERIFY_SERVICES` stores its command in the **third** form (`uptime-kuma:uptime-kuma
verify`), and `test-all` executes that string verbatim. So a service registered in
1 and 2 but not 3 looks correct interactively and fails under `test-all` — while a
service registered in 1 and 3 but not 2 does the reverse.

Two of nine services had this wrong. Both were recent additions, which suggests
the guide's wording is the cause rather than carelessness:

- **alloy** — missing 2 *and* 3, so its verify playbook was dead code entirely
- **uptime-kuma** — missing 3, so `test-all` could never verify it

Measured before the fix:

```
uis uptime-kuma verify  -> ✗ Unknown command: uptime-kuma
uis verify uptime-kuma  -> ✓ works
```

---

## Phase 1: Fix uptime-kuma and audit the rest

### Tasks

- [x] 1.1 Add the `uptime-kuma)` arm to the main command dispatch
- [x] 1.2 Add the missing `Uptime Kuma:` section to the top-level help — and,
      while in the same block, `Backstage:` and `Nextcloud:`, which dispatch
      correctly but were undocumented
- [x] 1.3 Audit all nine `VERIFY_SERVICES` entries against both dispatch tables

### Validation

Audit is clean:

```
service         stored command             uis verify <id>  uis <id> verify
alloy           alloy verify               OK               OK
argocd          argocd verify              OK               OK
backstage       backstage verify           OK               OK
enonic          enonic verify              OK               OK
minio           minio verify               OK               OK
nextcloud       nextcloud verify           OK               OK
openmetadata    openmetadata verify        OK               OK
temporal        temporal verify            OK               OK
uptime-kuma     uptime-kuma verify         OK               OK
```

Both forms run green against the live Uptime Kuma on **assist**, where it
actually runs (not asgard):

```
A. Web UI responds:        PASS (HTTP 302)
B. Identifies as Kuma:     PASS
C. Data volume mounted:    PASS
D. IngressRoute present:   PASS
PLAY RECAP: ok=15  changed=0  unreachable=0  failed=0
```

---

## Phase 2: Fix the guide, so this stops recurring

The defect keeps happening because the instructions are incomplete. Fixing only
the services leaves the trap armed for the next contributor.

### Tasks

- [ ] 2.1 Rewrite Step 5b's "two files to update" as three places, with the table
      above and a note on which form `VERIFY_SERVICES` stores
- [ ] 2.2 Add both invocations to the guide's Testing section, so a contributor
      exercises the path `test-all` will use
- [ ] 2.3 Consider a guard: have `test-all` (or a lint) fail loudly when a
      `VERIFY_SERVICES` entry does not dispatch, instead of reporting it as a
      service failure

### Validation

User review — this is a documentation judgement, not a testable change.

---

## Finding: `cluster-config.sh` on assist points at a context that does not exist

Not part of this plan's goal, recorded because it was found while testing and it
breaks a real path.

On **assist**, `cluster-config.sh` declares `TARGET_HOST="rancher-desktop"`, but
the merged kubeconfig offers only `asgard` and `assist`. Uptime Kuma's verify is
unaffected — like most verify playbooks it takes the ambient current-context —
but any playbook that pins `context: "{{ _target }}"` resolves to a context that
is not there. That includes all three alloy playbooks and the grafana setup.

Likely benign in origin: assist's monitoring stack was deployed from the ops repo
rather than through `uis`, so this install has probably never deployed anything.
It should still be corrected before `uis deploy` is used on assist, and it is a
good argument for `uis` validating `TARGET_HOST` against the available contexts
at startup rather than failing deep inside Ansible.
