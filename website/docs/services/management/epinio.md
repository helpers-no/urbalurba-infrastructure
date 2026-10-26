---
title: Epinio
sidebar_label: Epinio
---

# Epinio

Self-service source-to-URL deploy path (push code, get a URL, no kubeconfig)

| | |
|---|---|
| **Category** | Management |
| **Deploy** | `./uis deploy epinio` |
| **Undeploy** | `./uis undeploy epinio` |
| **Depends on** | cert-manager |
| **Required by** | None |
| **Helm chart** | `epinio/epinio` (unpinned) |
| **Default namespace** | `epinio` |

## What It Does

Epinio builds and deploys an application directly from source — no Kubernetes manifest, no kubeconfig for the developer. Alongside ArgoCD (which deploys a manifest the application brings) and uis (which provisions platform services), Epinio is UISs third deploy mechanism: for code that brings neither.

## Deploy

```bash
# Prerequisites — deploy dependencies first
./uis deploy cert-manager

# Deploy Epinio
./uis deploy epinio
```

## Verify

```bash
# Manual check
kubectl get pods -n epinio -l app.kubernetes.io/name=epinio-server
```

<!-- `./uis verify epinio` is not wired up yet — tracked in
     INVESTIGATE-service-epinio-deploy-path.md, not this doc's job to invent. -->

## Build safety — `epinio push --git` has no rollback

Epinio has no rollback or revision-history command, and a broken build can take a
previously-working app down: Epinio's readiness gate does not protect the old version while
staging a new one (measured live, `urb-agents#1911` Gate 8 — no configuration fix exists).
This is upstream Epinio behavior, not a UIS limitation, and it is specific to one of the two
ways to push:

- **`epinio push --container-image-url <registry-image>`** — build happens in CI (Forgejo
  Actions) before anything reaches Epinio. A broken build never produces an image, so this
  path is safe against Gate 8's failure mode by construction. **Use this if the app must
  stay up through a bad push.**
- **`epinio push --git <repo>`** — Epinio builds and deploys in one step, with no safety
  net. If the new build is broken, the previous version can go down with it, and the only
  recovery is pushing a known-good git ref again by hand. This remains the right choice for
  fast local iteration — just not for anything where a bad push must not take the app down.

See [PLAN-service-epinio-002-build-safety](../../ai-developer/plans/completed/PLAN-service-epinio-002-build-safety.md)
for the full decision.

## Configuration

<!-- MANUAL: Service-specific configuration details -->
_No configuration documentation yet. Edit this section to add details about Epinio settings, secrets, and customization options._

## Undeploy

```bash
./uis undeploy epinio
```

## Troubleshooting

<!-- MANUAL: Common issues and solutions -->
_No troubleshooting documentation yet. Edit this section to add common issues and their solutions._

## Learn More

- [Official Epinio documentation](https://epinio.io)
