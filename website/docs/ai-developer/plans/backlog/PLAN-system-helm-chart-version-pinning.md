# Fix: 16 of 24 Helm-based services take whatever the chart repo serves that day

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: Every `helm upgrade --install` in UIS names the chart version it was
tested with.

**Created**: 2026-08-21 — Terje, after Backstage broke on a floating dependency:
*"We must pin version so that we don't get these problems."*

**Investigation**: [INVESTIGATE-system-version-pinning](./INVESTIGATE-system-version-pinning.md)
— that investigation asks the general question; this is the measured Helm half.

**Related**: [PLAN-service-litellm-002-version-pinning](./PLAN-service-litellm-002-version-pinning.md)
(one instance, already filed), and the validation record
[STATUS-rancher-desktop-validation-2026-08-21](../completed/STATUS-rancher-desktop-validation-2026-08-21.md).

**Priority**: Medium-High — this is not a hypothetical risk. It cost a working
day on 2026-08-21.

---

## Problem

Measured across `ansible/playbooks/*setup*.yml`, 2026-08-21:

| | Count | |
|---|---|---|
| `helm upgrade --install` **with** `--version` | 8 | traefik `39.0.7`, authentik `2025.8.1`, temporal `1.6.0`, gravitee `4.11.3`, argocd `7.8.26`, openmetadata `1.12.1`, nextcloud `9.0.3`, backstage `7.0.1` |
| **without** `--version` | **16** | nginx, prometheus, alloy, tempo, loki, otel-collector, qdrant, minio, redis, elasticsearch, rabbitmq, openwebui (×2), litellm, spark, jupyterhub |

Two thirds of the observability stack is in the floating group.

### Why this is not theoretical

Backstage was undeployable on 2026-08-21. Three attempts, each ~10m 43s, each
ending `Error: UPGRADE FAILED: context deadline exceeded`. Nothing in UIS had
changed. The cause was a floating dependency resolved at install time, and the
same morning Red Hat hit the identical failure in their own CI
(redhat-developer/rhdh#5289, RHDHBUGS-3678).

The detail that matters for this plan: **the image was pinned and the chart was
not.** That is worse than pinning neither, because the pairing that runs is never
the pairing that was tested, and it changes with no commit and no signal.

### The failure shape

A floating chart does not fail loudly at bump time. It fails on the next clean
install, on someone else's machine, with an error that names something unrelated
— and `git log` shows nothing, because nothing in the repo changed. Every hour
spent is spent looking in the wrong place first.

---

## Phase 1: Pin what floats

### Tasks

- [ ] 1.1 For each of the 16, record the version currently resolving **and
      whether it is the version that last passed a test**. These are different
      questions; do not assume the current resolution is known-good
- [ ] 1.2 Add `--version` using the existing convention — a `<service>_chart_version`
      var beside the chart name, as traefik/argocd/temporal already do
- [ ] 1.3 Where a service pins its **image** but not its chart, note the pairing
      in a comment. That mismatch is what made Backstage expensive
- [ ] 1.4 Adopt argocd's comment style — it already says *"Specify the chart
      version to ensure reproducibility"*, which is the whole rationale in one line

### Validation

```bash
grep -L -- "--version" ansible/playbooks/*setup*.yml   # no helm playbook listed
./uis test-all --clean                                  # full sweep still passes
```

---

## Phase 2: Make regression impossible rather than unlikely

### Tasks

- [ ] 2.1 CI check: a playbook invoking `helm upgrade|install` without
      `--version` fails the build. Cheap grep, and it is the only thing that
      stops this returning service by service
- [ ] 2.2 Document the rule in [provisioning.md](../../../contributors/rules/provisioning.md)
      and add it to [adding-a-service.md](../../../contributors/guides/adding-a-service.md)
      Step 8, which currently covers adding a Helm *repo* but says nothing about
      pinning a chart
- [ ] 2.3 Decide and write down the bump policy — deliberate, tested, one service
      at a time. A pin nobody ever raises becomes its own problem

### Validation

A deliberately unpinned playbook fails CI.

---

## Phase 3: The wider question this exposes

Pinning the chart does not pin what the chart *fetches at install time*.

Backstage's failure was **not** the chart version. It was
`quay.io/rhdh/plugin-catalog-index:next` — a floating tag on a third-party
registry, resolved by an init container, listing content nobody here controls.
Pinning the chart would not have prevented it; not resolving the index did.

### Tasks

- [ ] 3.1 Identify services whose charts fetch further artefacts at install time
      (plugin catalogs, dynamic-plugin OCI refs, sidecar images with their own
      tags)
- [ ] 3.2 For each, decide: pin it, or stop fetching it. Backstage chose the
      second — UIS wanted none of that plugin set
- [ ] 3.3 Record the general rule: **a pinned chart is not a pinned deploy**

### Validation

For each such service, either the artefact is pinned or the fetch is disabled,
and which one is written down.

---

## Acceptance Criteria

- [ ] Every `helm upgrade --install` names a version
- [ ] CI fails an unpinned one
- [ ] The rule appears in the provisioning rules and the service-authoring guide
- [ ] Services pinning an image but not a chart are identified and fixed
- [ ] Install-time artefact fetches are enumerated and each is pinned or disabled
- [ ] A full `test-all --clean` passes after pinning

---

## Implementation Notes

**Do not pin blind.** Task 1.1 is the real work. Recording "what it resolves to
today" and calling it pinned freezes whatever drifted in, possibly mid-breakage.
The honest question is which version last passed a test, and for most of these
nobody knows — which is itself the finding.

**Start with the observability stack.** Six of the sixteen are prometheus, loki,
tempo, alloy, otel-collector and grafana's neighbours, they deploy as a unit, and
that unit is the one this validation run postponed. Pinning before testing it
means the test result refers to something reproducible.

---

## Files to Modify

- the 16 playbooks listed above
- `website/docs/contributors/rules/provisioning.md`
- `website/docs/contributors/guides/adding-a-service.md` — Step 8
- a CI lint, location TBD by Phase 2.1
