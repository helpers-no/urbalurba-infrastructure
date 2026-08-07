---
title: Registry cache
sidebar_label: Registry cache
sidebar_position: 4
---

# Registry cache

Without a local image cache, a cluster **cannot restart when upstream registries
are unreachable**. Running pods survive — their layers are already on the node —
but any restart, reschedule or scale-up fails to pull, and the service stays down.

That is the worst shape of failure: invisible until you need recovery, and it
bites hardest when something else is already broken.

Two everyday benefits besides outages:

- **Rate limits.** Anonymous pulls from public registries are throttled per IP; a
  cluster redeploying a stack can hit the limit mid-deploy.
- **Speed and bandwidth.** Re-deploying a full stack re-pulls gigabytes otherwise
  — and developer machines can use the same cache.

## It must live outside the cluster

A registry inside the cluster cannot serve the images required to start that
cluster. After a cold boot the cache's own pod needs an image, which needs the
cache. (In-cluster peer-to-peer layer sharing is useful for multi-node clusters
but does not solve cold start.)

## Shape

`registry:2` proxies exactly one upstream, so one instance per registry:

| Port | Upstream |
|---|---|
| 5000 | Docker Hub |
| 5001 | `registry.k8s.io` |
| 5002 | `ghcr.io` |
| 5003 | `quay.io` |

Alternatives worth evaluating: `zot` (multiple upstreams in one instance) or
Harbor (heavier, but garbage collection and auth included).

Point the cluster at them — for k3s, `/etc/rancher/k3s/registries.yaml`:

```yaml
mirrors:
  docker.io:
    endpoint: ["http://<cache-host>:5000"]
  registry.k8s.io:
    endpoint: ["http://<cache-host>:5001"]
```

k3s renders `certs.d/<registry>/hosts.toml` from this on restart. Upstream remains
the fallback, so the cache fails open.

## ⚠️ Warming the cache — the trap

**`crictl pull` does not warm the cache** when the image is already on the node.
It is a no-op that never contacts the mirror. On the reference build a warming
loop reported `pulled ok=41 failed=0` while the cache actually held **four
repositories**.

Request each image **from the mirror endpoint** instead:

```bash
skopeo copy --src-tls-verify=false \
  docker://<cache-host>:5000/library/<image>:<tag> dir:/tmp/warm && rm -rf /tmp/warm
```

⚠️ Official Docker Hub images need `library/` inserted in the mirror path.

**Verify with `/v2/_catalog`, never with the pull command's exit status.**

## Verify it actually works

The only meaningful test: block internet egress on **both** the cache host and a
cluster node, remove an image from the node, and pull it again. It should succeed
from cache. Remember to remove the test firewall rules afterwards.

## Housekeeping

The cache grows as tags churn. `registry:2` needs `REGISTRY_STORAGE_DELETE_ENABLED=true`
plus a periodic `registry garbage-collect`. The cache is fully reconstructible, so
it is a reasonable candidate to exclude from offsite backup — and it must be
re-warmed after deploying new services.
