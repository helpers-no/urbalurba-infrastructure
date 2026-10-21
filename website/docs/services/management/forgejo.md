---
title: Forgejo
sidebar_label: Forgejo
---

# Forgejo

Self-hosted git host + its own built-in OCI registry

| | |
|---|---|
| **Category** | Management |
| **Deploy** | `./uis deploy forgejo` |
| **Undeploy** | `./uis undeploy forgejo` |
| **Depends on** | None |
| **Required by** | forgejo-runner |

| **Default namespace** | `forgejo` |

## What It Does

Forgejo is a self-hosted git host with its own built-in OCI registry — the git host and image store Forgejo Actions (uis deploy forgejo-runner) pushes to and pulls from. The in-cluster counterpart of the dedicated Proxmox guest built for production.

## Deploy

```bash
# Deploy Forgejo
./uis deploy forgejo
```

## Verify

```bash
# Quick check
./uis verify forgejo

# Manual check
kubectl get pods -n forgejo -l app=forgejo
```

## Configuration

<!-- MANUAL: Service-specific configuration details -->
_No configuration documentation yet. Edit this section to add details about Forgejo settings, secrets, and customization options._

## Undeploy

```bash
./uis undeploy forgejo
```

## Troubleshooting

<!-- MANUAL: Common issues and solutions -->
_No troubleshooting documentation yet. Edit this section to add common issues and their solutions._

## Learn More

- [Official Forgejo documentation](https://forgejo.org)
