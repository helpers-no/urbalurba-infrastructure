# Fix: 21 playbooks declare a variable named `namespace`, which Ansible reserves

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: No playbook shadows an Ansible reserved name.

**Created**: 2026-08-21 — surfaced by a warning during the Rancher Desktop
validation run, see
[STATUS-rancher-desktop-validation-2026-08-21](../completed/STATUS-rancher-desktop-validation-2026-08-21.md).

**Priority**: Low — cosmetic today, and cheap. Recorded so it is not rediscovered.

---

## Problem

Deploying RabbitMQ emits:

```
[WARNING]: Found variable using reserved name: namespace
```

`080-setup-rabbitmq.yml` line 11 declares it in its `vars:` block:

```yaml
  vars:
    namespace: "default"
```

then references it as `namespace: "{{ namespace }}"` when passing it to modules —
a variable referring to itself, which is exactly what the reserved-name guard
warns about.

**Measured: 21 playbooks do this**, counted by parsing `vars:` blocks rather than
grepping for the string (most of the 66 files containing `namespace:` are using
it correctly, as a module parameter):

```
003-setup-traefik      003-remove-traefik      030-setup-prometheus   030-remove-prometheus
031-setup-alloy        031-remove-alloy        031-setup-tempo        031-remove-tempo
031-test-alloy         032-setup-loki          032-remove-loki        033-remove-otel-collector
080-setup-rabbitmq     … and the rest of the observability set
```

Concentrated in the observability playbooks and Traefik, which is worth noting:
those are the ones the validation run **postponed**, so this warning will appear
in volume the moment that batch runs.

### Why bother

It is a warning, not an error, and nothing has broken. Two reasons it is still
worth clearing:

1. **Warnings that are always present train people to ignore warnings.** The
   `kubernetes<24.2.0` notice in
   [PLAN-system-k8s-client-version-pin](./PLAN-system-k8s-client-version-pin.md)
   sits in the same output, and that one carries real risk.
2. Ansible's behaviour with a shadowed reserved name is not guaranteed across
   versions. It resolves today; a future release may resolve it differently, and
   the failure would be a value silently becoming something else.

---

## Phase 1: Rename

### Tasks

- [ ] 1.1 Rename the variable in all 21 playbooks. Suggested: `k8s_namespace`,
      or `_namespace` to match the existing underscore-prefixed extra-var
      convention in [provisioning.md](../../../contributors/rules/provisioning.md)
- [ ] 1.2 Update every reference within those files
- [ ] 1.3 Check the `remove-` playbooks alongside their `setup-` twins — they are
      paired in the list above and must not drift apart
- [ ] 1.4 Check whether any is a `test-` playbook (`031-test-alloy.yml` is), since
      those are reached by a different path

### Validation

```bash
./uis deploy rabbitmq        # no "reserved name" warning
./uis undeploy rabbitmq
```

A grep of `vars:` blocks finds no reserved names.

---

## Phase 2: Stop it coming back

### Tasks

- [ ] 2.1 Add the rule to [provisioning.md](../../../contributors/rules/provisioning.md)
      — a short "do not shadow Ansible reserved names" note with the list
- [ ] 2.2 Consider a lint in CI; the parse is simple (walk `vars:` blocks, compare
      keys against the reserved set)

### Validation

A deliberately-introduced `namespace:` in a `vars:` block is caught.

---

## Acceptance Criteria

- [ ] No playbook declares a variable named `namespace`
- [ ] Setup/remove/test playbook families are updated together
- [ ] The rule is written down
- [ ] A full deploy/undeploy sweep passes with no reserved-name warnings

---

## Files to Modify

- the 21 playbooks listed above
- `website/docs/contributors/rules/provisioning.md`
- a CI lint, location TBD
