# Fix: the provisioning rules teach the `kubectl run --rm -i` idiom that loses output

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: Stop the platform's own rules document from recommending a test idiom
that reports healthy services as failing.

**Created**: 2026-08-21 — found while writing
[PLAN-service-browserless-001-deploy](./PLAN-service-browserless-001-deploy.md),
by reading the rules docs the adding-a-service guide lists as prerequisites.

**Investigation**: [INVESTIGATE-system-verification-playbooks-usage](./INVESTIGATE-system-verification-playbooks-usage.md)
— this is the **propagation source** for that investigation's third and most
serious finding. The investigation asks why the same broken idiom appears across
many services' verify playbooks. This is why.

**Related**: [PLAN-service-grafana-deploy-gate-fix](./PLAN-service-grafana-deploy-gate-fix.md)
— diagnosed the mechanism in detail on Grafana; that plan fixed one instance,
this one stops new instances being written.

**Priority**: Medium — small fix, and it is upstream of an unknown number of
future defects.

---

## Problem

[`rules/provisioning.md`](../../../contributors/rules/provisioning.md) presents
this as the **correct** pattern, twice — once under "No .localhost Testing from
Host Context" and again under "Verification Standards → 2. Service connectivity
test":

```yaml
# CORRECT: Test from within the cluster using a temporary pod
- name: Test service connectivity from within cluster
  ansible.builtin.shell: |
    kubectl run curl-test --image=curlimages/curl --rm -i --restart=Never -n {{ namespace }} -- \
    curl -s -w "HTTP_CODE:%{http_code}" http://{{ service }}:{{ port }}/health
  register: service_test
  retries: 5
  delay: 5
  until: service_test.rc == 0 and (service_test.stdout.find('HTTP_CODE:200') != -1 or ...)
```

`kubectl run --rm -i` attaches to the pod to stream its output. When the
container finishes before the attach completes, kubectl **cannot retrieve the
logs from a pod that is already terminating** and returns **`rc=0` with empty
stdout** — diagnosed in detail in the Grafana plan, where the same command run by
hand returned the asserted string and `rc=0`, while the playbook saw `rc=0` and
no `HTTP_CODE` at all.

The `until:` condition then never becomes true, the task exhausts its retries,
and **a healthy service is reported as failing**. Load-dependent, so it passes on
a quiet laptop and fails in CI, or the reverse.

**The advice around it is correct and should be kept.** Not testing `.localhost`
from Ansible is right — the host resolves it to itself, not to Traefik in the
cluster. Testing from inside the cluster is right. Only the *mechanism* is unsafe.

### Why this is worth its own plan

The investigation records the defect and the Grafana plan records the diagnosis,
but both treat it as something found in playbooks. Neither records that the rules
document **tells contributors to write it that way**. Fixing services one at a
time while the guide keeps producing new ones is the same shape as the verify
registration defect: *"the guide's wording is the cause rather than carelessness."*

---

## Phase 1: Replace the recommended idiom

### Tasks

- [ ] 1.1 Choose the safe replacement. Candidates, to be decided with evidence
      rather than taste:
      - `kubectl run --restart=Never` **without** `--rm -i`, then
        `kubectl logs` the pod explicitly and delete it — output is read from a
        completed pod rather than raced against termination
      - a long-lived debug pod the playbook `exec`s into
      - `kubernetes.core.k8s_exec` against an existing pod
      - keep `--rm -i` but assert on something that cannot be silently empty
- [ ] 1.2 Verify the chosen replacement actually survives the race — run it
      enough times, under load, to show it does not intermittently return empty
- [ ] 1.3 Update **both** occurrences in `rules/provisioning.md`
- [ ] 1.4 Add a short "why not `--rm -i`" note next to it, so the old form is not
      reintroduced by someone who finds it shorter

### Validation

The documented command, run repeatedly under load, never returns `rc=0` with
empty stdout.

---

## Phase 2: Stop it silently reappearing

### Tasks

- [ ] 2.1 Grep `ansible/playbooks/` for the old idiom and list every occurrence.
      **This plan does not fix them** — that audit belongs to the investigation,
      which owns the systematic sweep. Produce the list and hand it over
- [ ] 2.2 Consider a lint or CI grep that fails when `--rm -i` is combined with an
      `until:` asserting on `stdout` — the same guard shape proposed as task 2.3
      of [PLAN-cli-verify-registration-fix](./PLAN-cli-verify-registration-fix.md)
- [ ] 2.3 Check whether `adding-a-service.md` or the integration-testing guide
      reproduce the idiom independently

### Validation

The occurrence list exists and is attached to the investigation. Any guard added
fails on a deliberately-introduced bad example.

---

## Acceptance Criteria

- [ ] `rules/provisioning.md` no longer recommends `kubectl run --rm -i` with an
      `until:` on stdout
- [ ] The replacement is demonstrated safe, not merely assumed
- [ ] The correct advice around it — no `.localhost` from Ansible, test from
      inside the cluster — is preserved unchanged
- [ ] Every existing occurrence is enumerated and handed to the investigation
- [ ] Nothing in this plan fixes individual services; that is deliberate

---

## Implementation Notes

**Why the fix is docs-first rather than a code sweep.** The investigation already
owns sweeping the playbooks. What it cannot do is stop new ones being written,
because the rules document is what new contributors read. Fix the source, then
sweep — otherwise the sweep has to be repeated.

**Do not delete the surrounding guidance.** It would be easy to read this plan as
"the connectivity-test section is wrong." It is not. The section's reasoning is
sound and its conclusion — test from inside the cluster — is right. One command
inside it races. Keep everything else.

---

## Files to Modify

- `website/docs/contributors/rules/provisioning.md` — both occurrences
- possibly `website/docs/contributors/guides/adding-a-service.md` and
  `website/docs/contributors/guides/integration-testing.md`, if they reproduce it
- a lint/CI guard, location TBD by Phase 2.2
