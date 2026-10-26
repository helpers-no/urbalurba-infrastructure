---
title: GitHub Runner
sidebar_label: GitHub Runner
---

# GitHub Runner

In-cluster GitHub Actions self-hosted runner (CI for GitHub-hosted repos)

| | |
|---|---|
| **Category** | Management |
| **Deploy** | `./uis deploy github-runner` |
| **Undeploy** | `./uis undeploy github-runner` |
| **Depends on** | None |
| **Required by** | None |

| **Default namespace** | `github-runner` |

## What It Does

Registers a GitHub Actions self-hosted runner against an operator-supplied repository, executing workflow jobs via a private docker:dind sidecar — the same proven architecture as forgejo-runner, for GitHubs own (incompatible) runner protocol instead of Forgejos. The SAME Deployment runs identically on Rancher Desktop and on a Proxmox k3s cluster.

## Deploy

```bash
# Deploy GitHub Runner
./uis deploy github-runner
```

## Verify

```bash
# Quick check
./uis verify github-runner

# Manual check
kubectl get pods -n github-runner -l app=github-runner
```

## Configuration

<!-- MANUAL: Service-specific configuration details -->
_No configuration documentation yet. Edit this section to add details about GitHub Runner settings, secrets, and customization options._

## Undeploy

```bash
./uis undeploy github-runner
```

## Troubleshooting

<!-- MANUAL: Common issues and solutions -->
_No troubleshooting documentation yet. Edit this section to add common issues and their solutions._

## Learn More

- [Official GitHub Runner documentation](https://docs.github.com/en/actions/hosting-your-own-runners)
