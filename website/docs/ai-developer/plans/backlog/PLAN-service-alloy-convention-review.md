# Review: bring Alloy in line with how other services are deployed and verified

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog — one defect already fixed, three remain

**Why this exists** (Terje, 2026-08-22): *"the alloy was added during summer
vacation and solely by an ai agent with no oversight from me. So it needs a fresh
look and to be brought in line with how other services is deployed and verified."*

**Context**: found while validating the observability stack on Rancher Desktop —
[STATUS-rancher-desktop-validation-2026-08-21](../completed/STATUS-rancher-desktop-validation-2026-08-21.md).

**Priority**: Low-Medium. Alloy works. Nothing here is urgent.

---

## The honest verdict

**Alloy is in better shape than the average UIS service, not worse.** That is
worth stating plainly rather than assembling a long list to justify the review.

Audited against [adding-a-service.md](../../../contributors/guides/adding-a-service.md)
and the contributor rules:

| Convention | Alloy |
|---|---|
| Complete service metadata (all `SCRIPT_*`) | ✅ |
| `NNN-<id>-config.yaml` = **Helm values** | ✅ genuinely Helm values, passed with `-f` |
| Manifest number matches playbook number | ✅ both `031` |
| Setup + remove playbooks | ✅ |
| **Verify playbook** | ✅ — only 10 of 34 services have one |
| Verify registered in every place | ✅ `VERIFY_SERVICES` + both grammar forms |
| Docs page + `sidebars.ts` entry | ✅ |
| Stack membership | ✅ in `observability` |

Its verify playbook's header is the clearest statement of the deploy-vs-works
distinction anywhere in the repo, and it is the reason the defect below was
caught at all:

> ⚠️ THE POINT OF THIS PLAYBOOK IS THE DIFFERENCE BETWEEN THOSE TWO THINGS.
> A DaemonSet can be perfectly healthy while shipping nothing.

---

## FIXED: the assertion accused the wrong service

Test 3 queried `/loki/api/v1/labels` — Loki's **global** label set — and failed
if `instance` appeared anywhere in it. That attributes every other shipper's
labels to Alloy.

On a healthy stack (2026-08-22) it failed. The command returned `rc=0` and a
valid response; `failed_when` marked it failed. The only stream carrying
`instance` was:

```json
{"job":"loki-validation","service_name":"loki-validation","instance":"test-pod"}
```

That is **Loki's own deploy-gate probe**, pushed by `032-setup-loki.yml` and left
behind after it passes. Alloy's config blanks `instance` correctly and none of
its streams carry it.

Fixed by scoping to `match[]={namespace=~".+"}` — Alloy's streams all carry
`namespace`, the probe does not. The assertion still catches the regression it
was written for; it now tests Alloy instead of the cluster. Verified: `ok=4
failed=0`.

**This was the fifth failure in one day that named the wrong service** — and the
only one where the accuser was a verify playbook, which is worse, because those
are the thing we are meant to trust.

---

## Phase 1: The two repo-wide patterns Alloy shares

Neither is Alloy-specific; both are already filed. Listed here so this review is
complete rather than because Alloy should be fixed alone.

### Tasks

- [ ] 1.1 **Pin the chart.** `helm upgrade --install {{ component_name }} grafana/alloy`
      has no `--version` — one of the 16 in
      [PLAN-system-helm-chart-version-pinning](./PLAN-system-helm-chart-version-pinning.md).
      Do it with the observability stack, not on its own
- [ ] 1.2 **Rename the reserved variable.** `namespace: "monitoring"` shadows an
      Ansible reserved name — one of the 21 in
      [PLAN-system-ansible-reserved-var-names](./PLAN-system-ansible-reserved-var-names.md).
      `031-setup-alloy.yml`, `031-remove-alloy.yml` and `031-test-alloy.yml` must
      move together

---

## Phase 2: The unsafe test idiom, twice

`031-test-alloy.yml` uses `kubectl run --rm -i` in two places. That call can
return `rc=0` with **empty stdout** when the container outlives the attach, so a
healthy service reads as failing — see
[PLAN-docs-provisioning-unsafe-test-idiom](./PLAN-docs-provisioning-unsafe-test-idiom.md).

It has not misfired here yet, and that is luck rather than design: the defect is
load-dependent and this box is slow.

### Tasks

- [ ] 2.1 Replace both with the run → wait-for-terminal-phase → `kubectl logs` →
      delete pattern. A worked example is in
      [088-test-postgrest.yml](https://github.com/helpers-no/urbalurba-infrastructure/blob/main/ansible/playbooks/088-test-postgrest.yml)
- [ ] 2.2 Sequence **after** the idiom fix lands, so Alloy adopts the agreed
      replacement rather than inventing a second one

---

## Phase 3: Loki leaves its probe data behind

Not an Alloy defect, but Alloy's verify is what surfaced it, and it is the other
half of the false failure.

`032-setup-loki.yml` pushes `{job="loki-validation", instance="test-pod"}` to
prove the write path works — a genuinely good test — and the data persists after
it passes. Test data that outlives its test is what tripped Alloy's assertion.

### Tasks

- [ ] 3.1 Decide whether Loki's probe should clean up. Loki has no delete API
      enabled by default, so the realistic options are a short-retention stream,
      a label that cannot collide, or accepting it and documenting why
- [ ] 3.2 If accepted, say so where the probe is pushed, so the next person
      debugging a stray label does not repeat this
- [ ] 3.3 Check the other deploy-gate probes for the same habit. Prometheus
      pushes to the Pushgateway and queries it back — same shape, same question

### Validation

A fresh stack install leaves no probe data that another service's verify can
mistake for its own.

**Measured on asgard (ops, 2026-08-22): the leftover does NOT manifest there.**
Loki's `job` values are only `["loki.source.kubernetes.pods"]` — no
`loki-validation`. Either retention aged it out or that installation's probe path
differs. So this is a Rancher-Desktop-visible problem rather than a universal one,
which lowers its priority but does not make it wrong: the Alloy assertion fix is
still the right general fix, and a fresh install is exactly where a contributor
would meet it.

---

## Acceptance Criteria

- [x] The assertion tests Alloy rather than the cluster
- [ ] Chart pinned, with the observability stack
- [ ] Reserved variable renamed across all three playbooks
- [ ] Both `kubectl run --rm -i` uses replaced
- [ ] Loki's probe data either cleaned up or documented as permanent
- [ ] `uis verify alloy` still passes after each change

---

## Implementation Notes

**What the review actually found.** The concern was that Alloy was added without
oversight. It holds up: the metadata, file naming, numbering, registration, docs
and stack membership are all correct, and it has a verify playbook when
two-thirds of the catalogue does not. The one genuine defect was in the verify's
*scope*, not its intent — and the intent is better than most.

The other three items are patterns Alloy shares with 16-21 other services. Fixing
them here alone would be worse than leaving them, because it would split those
sweeps.

**What the review does not cover.** Whether Alloy's log-collection *configuration*
is right for this platform — which pods it scrapes, what it drops, retention
implications. That is a different question from convention compliance and would
need someone who knows what the platform wants from its logs.
