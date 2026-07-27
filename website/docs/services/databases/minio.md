---
title: MinIO
sidebar_label: MinIO
---

# MinIO

S3-compatible object storage

| | |
|---|---|
| **Category** | Databases |
| **Deploy** | `./uis deploy minio` |
| **Undeploy** | `./uis undeploy minio` |
| **Depends on** | None |
| **Required by** | None |
| **Helm chart** | `minio/minio` (unpinned) |
| **Default namespace** | `default` |

## What It Does

MinIO is a high-performance, S3-compatible object storage server. Applications talk to it with any AWS S3 SDK, so code written against MinIO in UIS runs unchanged against AWS S3 or a production MinIO cluster later. It is deployed in standalone (single-node) mode with a persistent volume.

Key capabilities:

- **S3 API** on port `9000` — buckets, objects, presigned URLs, multipart uploads
- **Web console** on port `9001` — browse buckets, inspect objects, manage access keys
- **Persistent storage** — a PVC keeps every bucket across pod restarts and re-deploys
- **Root credentials from `urbalurba-secrets`** — nothing is hard-coded in the manifests
- **Same SDK everywhere** — `boto3`, `@aws-sdk/client-s3`, `minio-js`, `mc` all work unchanged

Typical uses: user uploads, generated image variants, exports and reports, build artifacts, database dumps.

## Deploy

```bash
./uis deploy minio
```

No dependencies.

Access after deploy:

| What | URL |
|------|-----|
| Console (browser) | `http://minio.localhost` |
| S3 API (browser / apps outside the cluster) | `http://s3.localhost` |
| S3 API (from inside the cluster) | `http://minio.default.svc.cluster.local:9000` |
| S3 API (from the host machine) | `./uis expose minio` → `http://localhost:39900` |

Log in to the console with `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD`.

## Verify

```bash
# Full E2E test suite (liveness, auth, console, bucket round-trip, routing)
./uis verify minio

# Manual check
kubectl get pods -n default -l app=minio

# Health endpoint (from inside the cluster)
kubectl run curl-test --image=curlimages/curl --rm -i --restart=Never -n default -- \
  curl -s -o /dev/null -w "%{http_code}\n" http://minio:9000/minio/health/live
```

## Configuration

MinIO configuration is in `manifests/045-minio-config.yaml`. Key settings:

| Setting | Value | Notes |
|---------|-------|-------|
| Mode | `standalone` | Single node, single drive — right shape for a dev cluster |
| S3 API port | `9000` | Service `minio` |
| Console port | `9001` | Service `minio-console` |
| Data storage | `20Gi` PVC `minio-data` | Created by the playbook, not by Helm, so `undeploy` keeps the data |
| Memory | 512Mi request / 2Gi limit | Chart default requests 16Gi and will not schedule |
| Buckets | none pre-created | Applications create their own buckets over the S3 API |

### Secrets

| Variable | File | Purpose |
|----------|------|---------|
| `MINIO_ROOT_USER` | `.uis.secrets/secrets-config/00-common-values.env.template` | S3 access key / console login |
| `MINIO_ROOT_PASSWORD` | `.uis.secrets/secrets-config/00-common-values.env.template` | S3 secret key / console password |
| `MINIO_HOST`, `MINIO_PORT`, `MINIO_ENDPOINT` | same file | Cluster-internal endpoint for applications |

All of them land in the `urbalurba-secrets` Secret in the `default` namespace. The setup playbook reads the root credentials from there and passes them to Helm, so no credential is ever stored in a manifest.

Read them back with:

```bash
kubectl get secret urbalurba-secrets -n default -o jsonpath='{.data.MINIO_ROOT_USER}' | base64 -d
kubectl get secret urbalurba-secrets -n default -o jsonpath='{.data.MINIO_ROOT_PASSWORD}' | base64 -d
```

To change them: edit `00-common-values.env.template`, then `./uis secrets generate`, `./uis secrets apply`, and re-deploy MinIO.

### Connecting an application

Applications running in the cluster mount `urbalurba-secrets` and use the S3 endpoint directly:

```yaml
env:
  - name: S3_ENDPOINT
    valueFrom:
      secretKeyRef: { name: urbalurba-secrets, key: MINIO_ENDPOINT }
  - name: S3_ACCESS_KEY
    valueFrom:
      secretKeyRef: { name: urbalurba-secrets, key: MINIO_ROOT_USER }
  - name: S3_SECRET_KEY
    valueFrom:
      secretKeyRef: { name: urbalurba-secrets, key: MINIO_ROOT_PASSWORD }
```

Two things every S3 SDK needs when pointing at MinIO:

- **Path-style addressing must be enabled** (`forcePathStyle: true` / `s3ForcePathStyle`). MinIO does not do virtual-host-style bucket subdomains by default.
- **A region must be set** even though MinIO ignores it — `us-east-1` is the usual choice.

Example (Node.js, AWS SDK v3):

```js
const s3 = new S3Client({
  endpoint: process.env.S3_ENDPOINT,          // http://minio.default.svc.cluster.local:9000
  region: 'us-east-1',
  forcePathStyle: true,
  credentials: {
    accessKeyId: process.env.S3_ACCESS_KEY,
    secretAccessKey: process.env.S3_SECRET_KEY,
  },
});
```

For development from the host machine (or a devcontainer), port-forward the S3 API:

```bash
./uis expose minio           # binds localhost:39900 -> svc/minio:9000
./uis expose minio --stop
```

### Key Files

| File | Purpose |
|------|---------|
| `manifests/045-minio-config.yaml` | Helm values (mode, storage, resources, services) |
| `manifests/046-minio-ingressroute.yaml` | Traefik routes: `minio.*` → console, `s3.*` → S3 API |
| `ansible/playbooks/045-setup-minio.yml` | Deployment playbook (reads credentials, waits, health-checks) |
| `ansible/playbooks/045-remove-minio.yml` | Removal playbook (keeps data unless `--purge`) |
| `ansible/playbooks/045-test-minio.yml` | E2E verification playbook (`./uis verify minio`) |

## Undeploy

```bash
# Removes the deployment, keeps all buckets and objects on the PVC
./uis undeploy minio

# Removes everything including the PVC — all objects are gone permanently
./uis undeploy minio --purge
```

## Troubleshooting

**Pod won't start / stays Pending:**

```bash
kubectl describe pod -n default -l app=minio
kubectl get pvc -n default -l app=minio
```

A Pending PVC usually means the cluster has no default StorageClass. The claim is named `minio-data` and lives outside the Helm release.

**Deploy fails with "MINIO_ROOT_USER / MINIO_ROOT_PASSWORD not found":**

The secret has not been applied to the cluster yet:

```bash
./uis secrets generate
./uis secrets apply
./uis deploy minio
```

**S3 requests return 403 SignatureDoesNotMatch:**

The access key / secret key pair does not match what MinIO was started with. This happens after rotating secrets without re-deploying. Fix with `./uis secrets apply` followed by `./uis undeploy minio` and `./uis deploy minio` (data on the PVC is preserved).

**Bucket exists but the app gets 404 on the bucket URL:**

Path-style addressing is not enabled in the SDK — see [Connecting an application](#connecting-an-application).

**Console loads but shows a blank page on an external domain:**

The console is served from the route root. Use a dedicated subdomain (`minio.<domain>`), not a path prefix.

## Learn More

- [Official MinIO documentation](https://min.io/docs/minio/kubernetes/upstream/)
- [MinIO Helm chart](https://github.com/minio/minio/tree/master/helm/minio)
- [MinIO client (`mc`) reference](https://min.io/docs/minio/linux/reference/minio-mc.html)
