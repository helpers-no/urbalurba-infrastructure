---
title: PLAN — a secret change must reach the running pod
sidebar_label: PLAN — secret propagation
---

# PLAN — a secret change must reach the running pod

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: nine pod templates read `urbalurba-secrets` through a `secretKeyRef` and carry nothing that changes when that secret does. Give them the same treatment oauth2-proxy and PostgREST already have — or a better, single mechanism.

## The property, and why it is invisible

A `secretKeyRef` env var binds at **container start**. Once the podspec carries the reference, changing the secret changes nothing about the podspec, so Kubernetes correctly does nothing and the process keeps the value it started with.

🔴 **Every surface reports success.** The deploy exits 0, the pod is healthy, the rollout completes. The only symptom is a process holding a value that is no longer true.

**Two of two examined were defects, and neither was found by reading:**

| service | how it surfaced |
|---|---|
| oauth2-proxy (1.6.126) | a credential rotation rolled nothing, and the gate kept the old secret |
| PostgREST (1.6.144) | a published API document advertised the wrong hostname |

⚠️ **It bites only on the upgrade path.** A fresh install gains the env reference in the same deploy, so the pod starts *after* the secret. Testing does not catch it; the installed base is the population at risk.

## The nine

All read `urbalurba-secrets`, which `./uis secrets apply` re-syncs — so "the secret never changes" is not available as an argument for this population. Each is marked `SECRET-VERSION: pending` beside its `secretKeyRef`, and `test-secret-version-propagation.sh` prints the count every run.

```
040-mongodb-config.yaml          230-uptime-kuma-autokuma.yaml    622-onlyoffice-config.yaml
043-database-mysql-config.yaml   320-unity-catalog-deployment.yaml 820-cloudflare-tunnel-base.yaml
085-enonic-statefulset.yaml      400-browserless-deployment.yaml  410-neko-deployment.yaml
```

## Two shapes, and the second is probably right

**Per-service annotation** — what oauth2-proxy and PostgREST have. Each deploy reads the secret's `resourceVersion` and puts it on the pod template. Nine manifests and nine playbooks, each verifiable on its own.

🔵 **Or make `uis secrets apply` own it.** That verb is what makes running pods stale, and the principle this repository has now applied twice is that **the operation which creates a divergence repairs it** — `template install` restarting Dagster's servers, `configure` syncing the spec URI. One change, every consumer, including the tenth service nobody has written yet.

⚠️ **It is a bigger action than the verb currently implies** — `secrets apply` would restart workloads — so it needs the same treatment `uis deploy dagster` got: report what it did, distinguish "rolled" from "nothing to do", and never claim the first while doing the second.

## Success criteria

- [ ] No pod template consuming `urbalurba-secrets` is `SECRET-VERSION: pending`
- [ ] A secret change followed by the documented remediation produces a **new ReplicaSet** — asserted by observing the ReplicaSet, not by the command exiting 0
- [ ] The gate still enumerates rather than consulting a list, so service number eleven cannot be added unexamined

## Related

- `urb-agents#1415` — the sweep, and the argument for a gate rather than ten patches
- `urb-agents#1413`, `#1411` — the two instances, and the "reported success, changed nothing" class they share
