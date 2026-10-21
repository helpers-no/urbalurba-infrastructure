---
title: Forgejo Runner
sidebar_label: Forgejo Runner
---

# Forgejo Runner

In-cluster Forgejo Actions runner (CI for Forgejo-hosted repos)

| | |
|---|---|
| **Category** | Management |
| **Deploy** | `./uis deploy forgejo-runner` |
| **Undeploy** | `./uis undeploy forgejo-runner` |
| **Depends on** | forgejo |
| **Required by** | None |

| **Default namespace** | `forgejo-runner` |

## What It Does

Registers a Forgejo Actions runner against this installs own Forgejo (uis deploy forgejo), executing workflow jobs via a private docker:dind sidecar. The in-cluster counterpart of the dedicated Proxmox VM runner built for production — same runner version and registration flow, different job-isolation mechanism because this target has no spare dedicated host.

## Deploy

```bash
# Prerequisites — deploy dependencies first
./uis deploy forgejo

# Deploy Forgejo Runner
./uis deploy forgejo-runner
```

## Verify

```bash
# Quick check
./uis verify forgejo-runner

# Manual check
kubectl get pods -n forgejo-runner -l app=forgejo-runner
```

## Configuration

<!-- MANUAL: Service-specific configuration details -->
_No configuration documentation yet. Edit this section to add details about Forgejo Runner settings, secrets, and customization options._

## Undeploy

```bash
./uis undeploy forgejo-runner
```

## Troubleshooting

<!-- MANUAL: Common issues and solutions -->
_No troubleshooting documentation yet. Edit this section to add common issues and their solutions._

## Learn More

- [Official Forgejo Runner documentation](https://forgejo.org/docs/latest/admin/actions/)
