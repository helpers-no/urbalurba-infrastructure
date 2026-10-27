---
title: Reflector
sidebar_label: Reflector
---

# Reflector

Mirrors a Secret/ConfigMap across namespaces, kept in sync automatically

| | |
|---|---|
| **Category** | Management |
| **Deploy** | `./uis deploy reflector` |
| **Undeploy** | `./uis undeploy reflector` |
| **Depends on** | None |
| **Required by** | None |
| **Helm chart** | `emberstack/reflector` (unpinned) |
| **Default namespace** | `reflector` |

## What It Does

Reflector watches Secrets/ConfigMaps annotated with reflector.v1.k8s.emberstack.com/reflection-allowed and mirrors them into other namespaces, re-syncing automatically on every change (a certificate renewal, a password rotation). Kubernetes volumes cannot cross namespaces on their own - a cert-manager Certificate issued once can still be trusted by a workload in a different namespace once that Secret is reflected into it.

## Deploy

```bash
# Deploy Reflector
./uis deploy reflector
```

## Verify

```bash
# Quick check
./uis verify reflector

# Manual check
kubectl get pods -n reflector -l app.kubernetes.io/name=reflector
```

## Configuration

<!-- MANUAL: Service-specific configuration details -->
_No configuration documentation yet. Edit this section to add details about Reflector settings, secrets, and customization options._

## Undeploy

```bash
./uis undeploy reflector
```

## Troubleshooting

<!-- MANUAL: Common issues and solutions -->
_No troubleshooting documentation yet. Edit this section to add common issues and their solutions._

## Learn More

- [Official Reflector documentation](https://github.com/emberstack/kubernetes-reflector)
