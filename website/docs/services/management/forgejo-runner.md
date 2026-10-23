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

Registers a Forgejo Actions runner against this installs own Forgejo (uis deploy forgejo), executing workflow jobs via a private docker:dind sidecar. The SAME Deployment runs identically on Rancher Desktop and on a Proxmox k3s cluster — only whether Forgejo is in-cluster or an external LXC guest differs, via the forgejo_external_url setup var.

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
The registration token is genuine site data, never defaulted or auto-minted — supply it with
`-e forgejo_runner_token=...` (see the CLI-gap note in `service-forgejo-runner.sh`'s own header
for why `uis deploy` can't pass it yet). Mint one after a Forgejo admin account exists:

```bash
kubectl exec -n forgejo deploy/forgejo -- forgejo actions generate-runner-token
```

**Targeting a Proxmox k3s cluster instead of Rancher Desktop**: this is the same Deployment
either way — the one setting that differs is whether Forgejo runs in this same cluster or
externally. Pass `-e forgejo_external_url=http://<forgejo guest IP>:3000/` to switch modes; the
in-cluster Deployment check, Service-DNS instance URL, and the `.localhost`/Traefik hostAliases
workaround are all skipped automatically when it's set, since a real LAN address has none of
those problems. `platforms/proxmox/scripts/forgejo-runner-pod-deploy.sh` is a thin wrapper that
resolves this address from `config.sh` and runs the setup playbook directly for you.

## Undeploy

```bash
./uis undeploy forgejo-runner
```

## Troubleshooting

<!-- MANUAL: Common issues and solutions -->
_No troubleshooting documentation yet. Edit this section to add common issues and their solutions._

## Learn More

- [Official Forgejo Runner documentation](https://forgejo.org/docs/latest/admin/actions/)
