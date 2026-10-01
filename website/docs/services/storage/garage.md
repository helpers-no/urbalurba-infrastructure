---
title: Garage
sidebar_label: Garage
---

# Garage

| | |
|---|---|
| **Category** | Storage |
| **Depends on** | None |
| **Required by** | None |
| **Image** | `dxflrs/garage:v2.3.0` (pinned - Garage publishes no `latest`) |
| **Default namespace** | `default` |

:::danger Written 2026-10-01, not yet verified on a cluster

Every command and configuration value on this page is reasoned from Garage's own
documentation (fetched the same day, with the image pull independently confirmed
against the real registry) and written to match UIS's existing conventions. Nobody
has watched `uis deploy garage` run yet. If you are reading this before `imac` has
reported a successful deploy, treat it as a design, not a fact.

:::

## What It Does

Garage is a lightweight, S3-compatible object storage server maintained by
[Deuxfleurs](https://garagehq.deuxfleurs.fr), a French hosting cooperative.
Applications talk to it with any AWS S3 SDK, the same way they would talk to MinIO
or AWS S3 itself.

**Why Garage, and why now.** UIS deployed MinIO for this role until 2026-10-01, when
MinIO's images were withdrawn from every public registry it checked - not
account-gated, actually gone (`urb-agents#1801`; see
[INVESTIGATE-service-minio-to-garage](../../ai-developer/plans/backlog/INVESTIGATE-service-minio-to-garage.md)
for the measurement). `uis deploy minio` cannot succeed on a cluster with no cached
MinIO image. Terje decided the same day to replace it.

Key capabilities:

- **S3 API** on port `3900` - buckets, objects, presigned URLs
- **Persistent storage** - a PVC keeps the bucket across pod restarts and re-deploys
- **A chosen credential, not a minted one** - the bootstrap access key and secret
  come from `urbalurba-secrets`, the same way MinIO's root credential did
- **No web console** - Garage ships none. See "What was left out" below

## 🔴 What is different from MinIO - read this before assuming parity

This is **not** a drop-in replacement in every respect.

| | MinIO | Garage |
|---|---|---|
| Root credential | a true root/admin key: can list, create and access **every** bucket | the bootstrap key is scoped to **one bucket** (`default-bucket`) and can create no other, over the S3 API |
| Creating a new bucket | `mc mb` - any client holding the root key, any time | `garage bucket create` via the CLI inside the pod - an operator/automation action, not something an application can self-serve |
| Web console | yes, port 9001 | none |
| Cluster "layout" | not applicable (single node just runs) | normally a manual step (`garage layout assign` / `apply`) - UIS avoids this using `--single-node --default-bucket`, a flag pair Garage has shipped since v2.3.0 for exactly this case |

⚠️ **The consequence that matters most:** if a second UIS consumer wants its own
bucket (today, nothing does - the Loki/Tempo migration off MinIO is a separate,
not-yet-filed piece of work), someone has to run `garage bucket create` +
`garage key create` + `garage bucket allow` by hand or via a new playbook task.
There is no `uis configure garage` yet. Filed as a gap, not built speculatively -
see the investigation.

## Deploy

```bash
./uis deploy garage
```

No dependencies.

Access after deploy:

| What | URL |
|------|-----|
| S3 API (browser / apps outside the cluster) | `http://s3.localhost` or `http://garage.localhost` |
| S3 API (from inside the cluster) | `http://garage.default.svc.cluster.local:3900` |
| S3 API (from the host machine) | `./uis expose garage` → `http://localhost:39901` |

🔵 **`s3.<domain>` is shared with MinIO's IngressRoute on purpose** - it is the
protocol name, not the implementation, so an application configured against it does
not need to change when the object store behind it does. ⚠️ **Do not deploy both at
once**: with both present, which one actually answers `s3.<domain>` is undefined.
The setup playbook warns if it finds MinIO's Service still there.

Credentials:

```bash
kubectl get secret urbalurba-secrets -n default -o jsonpath='{.data.GARAGE_ACCESS_KEY}' | base64 -d
kubectl get secret urbalurba-secrets -n default -o jsonpath='{.data.GARAGE_SECRET_KEY}' | base64 -d
```

Region is `garage` (Garage's own default; S3 SDKs require a region string even
though Garage, like MinIO, does not use it for routing).

## What was left out, deliberately

- **No console.** Garage ships none, so there is nothing to add.
- **No `[s3_web]` section** (Garage can serve bucket contents as a static website).
  Not a UIS use case today.
- **No `[admin]` section** (Garage's HTTP admin API, separate from the S3 API).
  Nothing in UIS calls it - bucket and key administration is done via the `garage`
  CLI inside the pod, matching Garage's own Kubernetes cookbook
  (`kubectl exec ... -- ./garage status`). Add it if something needs it; it is not
  a security boundary being skipped, it is unused surface not being built.
- **Garage's own Helm chart.** It lives only in Garage's git repository - no
  Helm-repo index, no versioned `.tgz` to pin, which is part of why MinIO's own
  chart going stale went unnoticed for so long. It also needs a
  CustomResourceDefinition for one discovery mode and is built for a real
  multi-node, geo-distributed cluster: two PersistentVolumeClaims per replica, a
  manual layout step after every install. None of that fits one dev-laptop
  instance, so UIS runs the official image directly instead.

## Troubleshooting

- Check pods: `kubectl get pods -n default -l app=garage`
- View logs: `kubectl logs -n default -l app=garage`
- Check the layout configured: `kubectl exec -n default <pod> -- /garage status`
- Check the bootstrap bucket exists: `kubectl exec -n default <pod> -- /garage bucket list`
- Verify end-to-end: `./uis verify garage`

## Removing

```bash
./uis undeploy garage          # keeps the PVC - bucket data survives
./uis undeploy garage --purge  # deletes the PVC - PERMANENTLY destroys bucket data
```
