# Fix: pin the LiteLLM chart and image to reproducible versions

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: Two installs of the same UIS revision must deploy the same LiteLLM.

**Investigation**: [INVESTIGATE-service-litellm-install-reliability.md](./INVESTIGATE-service-litellm-install-reliability.md)

**Priority**: High

**Last Updated**: 2026-08-06

---

## Problem

`manifests/220-litellm-config.yaml` pins nothing:

```yaml
image:
  repository: ghcr.io/berriai/litellm-database
  tag: "main-latest"          # rolling main-branch build
  pullPolicy: Always
```

and `210-setup-litellm.yml` installs the chart with no `--version`.

Consequences:

- `main-latest` is **pre-release code from the main branch**. It currently
  resolves to LiteLLM **1.97.0** while the newest stable release is **v1.95.0**.
- With `pullPolicy: Always`, **any pod restart can silently change the version**
  — including a restart triggered by an unrelated node event.
- A developer on Rancher Desktop and a production cluster installed a week apart
  are running different code. This breaks the parity promise directly.
- Reproducing a bug report becomes guesswork, because "which version" has no
  answer.

The tag also carries a stale debugging comment: `# Back to latest - should have
the fix`.

---

## Solution

Pin both the chart and the image to explicit stable versions, in one place, with
a documented procedure for moving them.

---

## Phase 1: Pin

### Tasks

- [ ] 1.1 Determine the newest stable LiteLLM release and the matching
      `litellm-helm` chart version (stable = no `-rc`/`-dev` suffix)
- [ ] 1.2 Replace `tag: "main-latest"` with the stable image tag in
      `manifests/220-litellm-config.yaml`; remove the stale comment
- [ ] 1.3 Change `pullPolicy: Always` to `IfNotPresent` — with a fixed tag,
      `Always` only adds a registry round trip and a failure mode when the
      registry is unreachable (relevant to offline restart, see the registry
      cache investigation)
- [ ] 1.4 Add `--version <chart-version>` to the `helm upgrade --install` command
      in `210-setup-litellm.yml`
- [ ] 1.5 Record both versions in a comment at the top of the values file, with
      the date they were chosen

### Validation

```bash
kubectl get deploy litellm -n ai \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# -> ghcr.io/berriai/litellm-database:<pinned tag>, not main-latest

helm list -n ai   # chart version matches the pin
```

User confirms the pinned version deploys and serves models.

---

## Phase 2: Make upgrading deliberate

### Tasks

- [ ] 2.1 Document the upgrade procedure: how to find the current stable
      release, how to bump both pins together, how to roll back
- [ ] 2.2 Note the constraint that image and chart versions must be moved
      together, since chart values keys can change between majors

### Validation

User confirms the procedure is followable without reading the chart source.

---

## Acceptance Criteria

- [ ] No rolling tags (`main-latest`, `latest`) anywhere in the LiteLLM manifests
- [ ] The Helm install specifies an explicit chart version
- [ ] A pod restart cannot change the running version
- [ ] The upgrade path is documented
- [ ] `pullPolicy` is appropriate for a fixed tag

---

## Implementation Notes

Worth checking whether other services carry the same problem before closing
this out — the fix is per-service, but the *policy* ("no rolling tags in
manifests") should be uniform. There is an existing
`INVESTIGATE-system-version-pinning.md` in the backlog; this plan should be
reconciled with it rather than duplicating it.

---

## Files to Modify

- `manifests/220-litellm-config.yaml`
- `ansible/playbooks/210-setup-litellm.yml`
