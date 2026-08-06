# Fix: default LiteLLM config only works on Docker Desktop

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: A first-time `uis deploy litellm` should produce a usable model list on
any cluster, and the playbook's model check should actually run.

**Investigation**: [INVESTIGATE-service-litellm-install-reliability.md](./INVESTIGATE-service-litellm-install-reliability.md)

**Priority**: Medium

**Last Updated**: 2026-08-06

---

## Problem

Two independent defects in the same area.

### F7 — `host.docker.internal` in the default ConfigMap

When no `ai-models-litellm` ConfigMap exists, task 3.1 creates one containing:

```yaml
- model_name: llama3.2
  litellm_params:
    model: ollama_chat/llama3.2
    api_base: "http://host.docker.internal:11434"
```

`host.docker.internal` is a Docker Desktop / Rancher Desktop convenience name. On
a real k3s node it does not resolve. A first install on a server therefore ends
with exactly one model, which cannot answer — while `/v1/models` still lists it,
so the failure only appears at inference time.

This is a dev-only assumption baked into the default path: the same class of
problem as the Traefik v2/v3 mismatch, where the developer environment and the
server environment quietly diverge.

### F8 — The model verification task reads the wrong ConfigMap

Task 13 reads a ConfigMap named `litellm-config`:

```yaml
name: litellm-config
```

but tasks 3 and 3.1 create **`ai-models-litellm`**. The task is guarded by
`when: litellm_configmap.resources | length > 0`, so it finds nothing, skips
silently, and the "expected model count" comparison in tasks 14–15 never runs.
A verification step that never executes is worse than no verification, because
the play still prints "Models loaded and verified".

---

## Solution

Make the default portable and honest, and fix the ConfigMap reference so the
existing check does its job.

---

## Phase 1: Portable default

### Tasks

- [ ] 1.1 Decide the default behaviour when no model ConfigMap exists. Options:
      (a) ship no models and say so clearly, (b) detect Rancher Desktop and only
      then use `host.docker.internal`, (c) ship a commented-out example
- [ ] 1.2 Implement the chosen default in task 3.1
- [ ] 1.3 Make the deploy output state plainly when the model list is empty or
      placeholder-only, and how to supply a real one
- [ ] 1.4 Document the "apply your ConfigMap *before* `uis deploy litellm`"
      pattern — the playbook only creates a default when one is absent, which is
      the supported way to keep a custom model list across redeploys

### Validation

```bash
./uis deploy litellm      # on a non-Docker-Desktop cluster
# default model list is either empty-and-stated, or reachable
```

User confirms a first install on a server is not silently broken.

---

## Phase 2: Fix the model check

### Tasks

- [ ] 2.1 Change task 13 to read `ai-models-litellm`
- [ ] 2.2 Confirm tasks 14–15 now compare expected vs actual model names
- [ ] 2.3 Decide whether a mismatch should warn or fail; given the pattern in
      this investigation, prefer failing over printing SUCCESS

### Validation

```bash
./uis deploy litellm
# task 15 output lists the models from ai-models-litellm and compares them
```

User confirms the check runs and reports real numbers.

---

## Acceptance Criteria

- [ ] No `host.docker.internal` on a code path that runs on a server
- [ ] A first install either has working models or says clearly that it has none
- [ ] Task 13 reads the ConfigMap that actually exists
- [ ] The model count comparison executes rather than skipping
- [ ] The pre-apply pattern for custom model lists is documented

---

## Implementation Notes

Recommend option (a) for Phase 1.1 — ship no models and say so. A placeholder
that looks like a model but cannot answer is the same silent-success pattern
this whole investigation is about. An empty list with a clear message is honest
and immediately actionable.

---

## Files to Modify

- `ansible/playbooks/210-setup-litellm.yml` (tasks 3.1 and 13)
