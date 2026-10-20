---
title: cert-manager
sidebar_label: cert-manager
---

# cert-manager

X.509 certificate issuance and renewal for Kubernetes

| | |
|---|---|
| **Category** | Management |
| **Deploy** | `./uis deploy cert-manager` |
| **Undeploy** | `./uis undeploy cert-manager` |
| **Depends on** | None |
| **Required by** | epinio |
| **Helm chart** | `jetstack/cert-manager` (unpinned) |
| **Default namespace** | `cert-manager` |

## What It Does

cert-manager automates the issuance and renewal of X.509 certificates inside the cluster. UIS installs it with one self-signed ClusterIssuer (uis-ca) that other services ask for a real certificate, instead of relying on Traefiks ad-hoc per-connection default.

## Deploy

```bash
# Deploy cert-manager
./uis deploy cert-manager
```

## Verify

```bash
# Quick check
./uis verify cert-manager

# Manual check
kubectl get pods -n cert-manager -l app.kubernetes.io/component=webhook
```

## Configuration

<!-- MANUAL: Service-specific configuration details -->
_No configuration documentation yet. Edit this section to add details about cert-manager settings, secrets, and customization options._

## Undeploy

```bash
./uis undeploy cert-manager
```

## Troubleshooting

<!-- MANUAL: Common issues and solutions -->
_No troubleshooting documentation yet. Edit this section to add common issues and their solutions._

## Learn More

- [Official cert-manager documentation](https://cert-manager.io)
