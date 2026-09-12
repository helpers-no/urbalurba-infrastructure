# Plan: the install verifies the IngressRoute was created, not that it routes

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Backlog

**Goal**: an install must not report a working URL for a route that cannot serve
a request.

**Found**: 2026-09-11 by `imac` during acceptance, reported by `ops-dev`
(`urb-agents#726` finding 5). Measured on a real install, not read off the code.

---

## What it reported, and what was true

```
route created:    traefik.io/v1alpha1       HostRegexp(...)      <- v3 group, v3 syntax
traefik running:  2.10.5                    traefik.containo.us  <- v2 group, EMPTY
curl -H 'Host: api-atlas.localhost'  ->     404
```

The install printed a smoke-test URL and exited 0. 🔴 **The object existed, so
`kubernetes.core.k8s` was satisfied; the running Traefik was watching a
different API group and never saw it.**

⚠️ The v2/v3 mismatch itself is imac's host — a consequence of the k3s reset in
`#646`. **The check reporting success is ours.** A host can be wrong; a verifier
saying "ready" about a route that 404s is the defect.

## The precedent is in this repo already

`360-test-dagster.yml` gets this exact distinction right:

```
D1. Ask Dagster which code locations actually LOADED
```

and states the reason in its own summary — *"D asks the orchestrator whether
locations LOADED — a Deployment that exists"* is not the same claim. **The
ingress check infers from `kubectl` what the Dagster check refuses to infer.**

## 🔴 The obvious mechanism is not available — check this before designing

The natural analogue is "ask Traefik", via its API:

```
GET /api/http/routers   ->  does a router exist for this rule?
```

⚠️ **UIS disables it.** `manifests/003-traefik-config.yaml`:

```yaml
dashboard:
  enabled: false  # Set to true if you want the dashboard exposed
```

So an API-based check requires changing platform configuration for every
installation in order to verify one application's route. **That trade is the
first thing to decide, and it is why this plan does not simply say "ask
Traefik".**

## Two candidate mechanisms

**A — make a real request through Traefik.** From inside the cluster, request
the route's own host and assert a response the application would produce
(PostgREST serves an OpenAPI document at `/`), not merely "not a connection
error".

- 🟢 Authoritative: it is the thing the operator will do.
- ⚠️ Must distinguish **Traefik's** 404 (no router matched) from the
  application's own 404, or it trades a false pass for a false fail. A positive
  assertion on the body is what makes this sound; "not 404" is not enough.

**B — compare the API group applied against the group the running Traefik
serves.** Traefik v2 serves `traefik.containo.us`, v3 serves `traefik.io`.

- 🟢 Cheap, deterministic, and names the cause rather than the symptom.
- ⚠️ This is inference from `kubectl` — the very move the Dagster check avoids.

**Recommendation: A as the verdict, B as the explanation.** A answers *does it
route*; B answers *why not*, and B alone would have told imac exactly what was
wrong in one line.

## Scope

Every playbook that applies an IngressRoute makes this claim, not only
PostgREST — `045-setup-minio`, `034-setup-grafana`, `220-setup-argocd`,
`210-setup-litellm`, `641-adm-pgadmin` and others all apply
`traefik.io/v1alpha1` and report success on creation. **Fix the shared check
once rather than per service.**

## Acceptance

- On a host whose Traefik does not serve the applied group, the install **fails
  or warns by name** instead of printing a smoke-test URL.
- The message distinguishes *"the route does not route"* from *"could not
  check"*.
- Verified on a cluster where the mismatch is real — this cannot be accepted
  from a unit test, because the whole defect is that the object looks correct.
