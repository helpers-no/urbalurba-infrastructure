---
title: External Secrets Operator
sidebar_label: External Secrets
---

# External Secrets Operator

Syncs Kubernetes Secrets from external secret stores via ExternalSecret/ClusterSecretStore

| | |
|---|---|
| **Category** | Management |
| **Deploy** | `./uis deploy external-secrets` |
| **Undeploy** | `./uis undeploy external-secrets` |
| **Depends on** | None |
| **Required by** | bao |
| **Helm chart** | `external-secrets/external-secrets` |
| **Default namespace** | `external-secrets` |

## What It Does

External Secrets Operator (ESO) reads `ExternalSecret` resources and materialises them as ordinary
Kubernetes Secrets, sourced from a named `ClusterSecretStore`. This installs the operator and its
CRDs only — no `ClusterSecretStore` exists yet. A service that needs one creates and owns it (e.g. OpenBao's `openbao` store, via `./uis deploy bao`).
That split means the same `ExternalSecret` a developer writes on a laptop resolves identically
wherever the store it names actually exists.

## Deploy

```bash
# Deploy External Secrets Operator
./uis deploy external-secrets
```

## Verify

```bash
# Quick check
./uis verify external-secrets

# Manual check
kubectl get pods -n external-secrets
kubectl get clustersecretstores
```

## Configuration

<!-- MANUAL: Service-specific configuration details -->
_No configuration documentation yet. Edit this section to add details about ESO settings and
customization options._

## Undeploy

```bash
./uis undeploy external-secrets
```

Removal is refused while any `ClusterSecretStore` still exists (e.g. while `bao` is deployed) —
undeploy the services that own a store first, or pass `-e force=true` to the remove playbook.

## Troubleshooting

<!-- MANUAL: Common issues and solutions -->
_No troubleshooting documentation yet. Edit this section to add common issues and their solutions._

## Learn More

- [Official External Secrets Operator documentation](https://external-secrets.io)
