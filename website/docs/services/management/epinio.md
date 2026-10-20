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
# Quick check
./uis verify epinio

# Manual check
kubectl get pods -n epinio -l app.kubernetes.io/name=epinio-server
```

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
