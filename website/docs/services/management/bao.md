---
title: OpenBao
sidebar_label: OpenBao
---

# OpenBao

Secrets management (KV v2 + kubernetes auth), exposed to the cluster via a ClusterSecretStore

| | |
|---|---|
| **Category** | Management |
| **Deploy** | `./uis deploy bao` |
| **Undeploy** | `./uis undeploy bao` |
| **Depends on** | [external-secrets](./external-secrets.md) |
| **Required by** | None |
| **Helm chart** | `openbao/openbao` |
| **Default namespace** | `bao` |

## What It Does

OpenBao holds this platform's secrets in production
([platforms/proxmox/ansible/roles/bao](https://github.com/helpers-no/urbalurba-infrastructure/tree/main/platforms/proxmox/ansible/roles/bao),
built and proven against real hardware) but, until now, had no in-cluster dev form — a Principle 0
violation named explicitly in `adding-a-service.md`.

This deploys a **real** OpenBao in-cluster, not a fake backend standing in for the interface:

- **raft storage** — same storage backend production uses.
- **a static (auto-unseal) seal**, generated fresh per install and never regenerated — replacing it
  makes every existing secret unreadable, same rule production's role follows. Unlike Shamir, it
  comes back up unattended after a pod restart.
- **the `kubernetes` auth method**, configured with the in-cluster API server and CA (every pod
  already has these mounted — simpler than production, which validates callers in a *different*
  cluster and needs a cross-cluster kubeconfig read).
- a KV v2 mount named `platform` — the same name production uses, so a path a developer writes in
  an `ExternalSecret` is the same path that exists in production.
- a `ClusterSecretStore` named `openbao` — the actual interface a developer's `ExternalSecret`
  depends on. Requires [External Secrets Operator](./external-secrets.md) (`SCRIPT_REQUIRES`).

### Deliberate dev-only deviations from production

Stated plainly in `manifests/027-bao-config.yaml`'s own header, not hidden:

- **TLS is disabled.** Production terminates TLS with a private CA because it is reachable from
  outside the cluster; this instance is reachable only pod-to-pod inside one Rancher Desktop
  cluster. Revisit if this is ever exposed beyond the cluster.
- **Audit logging is off.** Production rotates a real audit log because it is a real incident
  record; a throwaway dev instance generates nothing worth auditing.
- **A 1Gi data volume**, not a production capacity plan.
- **The dev seed.** At deploy time, the entire `urbalurba-secrets` Kubernetes Secret is written to
  one KV v2 entry, `platform/urbalurba-secrets` — one source of truth for dev credentials, no
  second seed file. This is coarser-grained than whatever per-app path layout production's real
  OpenBao may use; a developer's `ExternalSecret` must still name the real path it needs.

## Deploy

```bash
# Deploy OpenBao (requires external-secrets)
./uis deploy external-secrets
./uis deploy bao
```

## Verify

```bash
# Quick check
./uis verify bao

# Manual check
kubectl get pods -n bao
kubectl exec -n bao bao-0 -- bao status
kubectl get clustersecretstore openbao
kubectl get secret bao-ensure-selftest -n external-secrets
```

## Configuration

<!-- MANUAL: Service-specific configuration details -->
_No configuration documentation yet. Edit this section to add details about bao settings, secrets,
and customization options._

## Undeploy

```bash
./uis undeploy bao
```

The seal key, the persisted root token, and the raft data volume are **preserved** by default —
undeploying and redeploying brings the same vault back, unsealed. Pass `-e _purge=true` to the
remove playbook to delete all three and start from nothing.

## Troubleshooting

<!-- MANUAL: Common issues and solutions -->
_No troubleshooting documentation yet. Edit this section to add common issues and their solutions._

## Learn More

- [Official OpenBao documentation](https://openbao.org)
- [External Secrets Operator](./external-secrets.md)
