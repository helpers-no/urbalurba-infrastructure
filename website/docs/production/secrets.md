---
title: Secrets
sidebar_label: Secrets
sidebar_position: 3
---

# Secrets in production

UIS ships secret **distribution** — templates rendered into one Kubernetes Secret
applied to every namespace. That is the right shape for a laptop. Production also
needs secret **management**: a store, encryption at rest, scoped access, audit and
rotation.

On a real deployment, the developer default measured as: cluster secret encryption
**disabled**, and one Secret containing **54 keys, base64 only, replicated into 13
namespaces** — so read access in any namespace yields every credential.

## The shape

```
backend (per environment)      cloud → managed key vault
   │                           on-prem → self-hosted store
   ▼
External Secrets Operator      identical in both
   ▼
ordinary Kubernetes Secret     the application is unchanged
```

**This is the important property:** an application's manifests are identical in
cloud and on-premises. Only the `ClusterSecretStore` backend differs — the same
trick UIS already uses for services.

## Why the store lives outside the cluster

Beyond the general [production principles](./index.md#1-state-lives-outside-the-cluster):
you need secrets to *start* a cluster, and to *rebuild* a dead one. A vault inside
the cluster it protects is circular.

**And for a deployment that must survive provider outages, the store must be local
too** — a cloud KMS on the startup path means no cloud, no cluster.

## Choosing a store

| Option | Notes |
|---|---|
| **OpenBao** | MPL-2.0, Vault-API compatible, light. **Auto-unseal without a cloud KMS** (static key, PKCS#11/TPM). Used for the reference build. |
| HashiCorp Vault | Same features; BUSL licence — source-available, not OSI open source. |
| Infisical | Strong UI, MIT core, no seal concept — but documented at 2–4 CPU / 4–8 GB per instance. |
| SOPS + age | No service at all; excellent for GitOps. No audit, API or dynamic secrets. |
| Sealed Secrets | Controller key lives **inside** the cluster → fails the bootstrap test. |

⚠️ **Auto-unseal matters more than it looks.** A vault that seals on restart needs
a human after every power cut. Verify unattended reboot before calling it done.

## Reference build (OpenBao)

1. **Container beside the cluster**, data on a snapshotted dataset.
2. **Auto-unseal configured before initialising** — otherwise you inherit a Shamir
   seal and manual unsealing. Then `operator init` with recovery shares.
3. **Verify by rebooting** and confirming `Sealed: false` with no intervention.
4. **Kubernetes auth**, so the operator authenticates with its own ServiceAccount
   token — no static credential stored in the cluster. This is the closest
   equivalent to a cloud "managed identity".
5. **External Secrets Operator** + a `ClusterSecretStore`; services then consume
   ordinary Secrets.

Then a service consumes a secret like this:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
spec:
  secretStoreRef: { name: <store>, kind: ClusterSecretStore }
  target: { name: myapp-secrets }
  data:
    - secretKey: API_KEY
      remoteRef: { key: myapp, property: api_key }
```

## Restrict the network

A vault on a flat LAN is reachable by every device on it. Enable TLS (with the
service IP in the certificate SANs) and firewall the API to the hosts that need
it. If peers share an L2 segment, match on **MAC as well as IP** — that survives
DHCP changes without router configuration.

⚠️ Putting the vault on an overlay network **without ACLs** is worse than a
restricted LAN: every node on the overlay can then reach it.

## What developers see: nothing

Secrets fall into three groups and developers meet only one:

| Group | Source | Developer sees it? |
|---|---|---|
| App credentials | `uis configure <svc> --app <name>` — minted **per environment**, never promoted | yes, as connection JSON |
| Platform secrets | the vault | no |
| Third-party app secrets | today, the values template | sometimes |

Local development is unchanged: no vault to install, no login, offline work still
possible. This mirrors cloud practice — nobody runs a managed key vault on a laptop.

The one genuine change is where a *production* third-party API key goes, which is
the natural place for a future `uis secret set` command.

## Operating it

- Rotation is always two parts: change the credential in the owning system, then
  update the store. **The store does not rotate anything for you.**
- The recovery keys are the one artifact that must live **outside every machine** —
  a password manager or paper.
- Revoke the initial root token once setup is complete.
