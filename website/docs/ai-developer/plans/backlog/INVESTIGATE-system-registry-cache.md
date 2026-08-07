# Investigate: Registry cache — a UIS cluster cannot currently restart without the internet

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: Give UIS a pull-through registry cache so a cluster can restart,
reschedule and self-heal with no internet access — and so repeated deploys stop
re-downloading the same layers and stop being subject to Docker Hub rate limits.
UIS has no registry mirror concept today; a working reference implementation was
built and outage-tested on a production Proxmox deployment, and the findings
(including two non-obvious traps) are recorded here.

**Related**: [INVESTIGATE-system-observability](./INVESTIGATE-system-observability.md),
[INVESTIGATE-system-remote-deployment-targets](./INVESTIGATE-system-remote-deployment-targets.md)
**Created**: 2026-08-05 — built and verified on k3s cluster `asgard` / Proxmox host `odin`

---

## Background

A UIS deployment pulls images from `registry.k8s.io`, `docker.io`, `ghcr.io` and
`quay.io`. On the production cluster surveyed, **41 distinct images** across those
four upstreams.

There is no mirror or cache anywhere in UIS:

```bash
grep -rl 'registries.yaml\|registry-mirror\|pull-through' .   # → no matches
```

### The failure mode this creates

If upstream registries are unreachable — an outage, an ISP problem, a rate limit,
or simply an air-gapped site — then:

- **already-running pods keep running** (their layers are on the node), so nothing
  looks wrong at first;
- **any restart, reschedule, node reboot or scale-up fails to pull**, and the
  affected service stays down until connectivity returns.

That is the worst shape of failure: invisible until the moment you need recovery,
and it hits hardest exactly when other things are already broken.

### Three reasons this matters beyond outages

1. **Docker Hub rate limits.** Anonymous pulls are throttled per IP. A cluster
   redeploying a stack, or several developers on one office IP, can hit the limit
   and see confusing `toomanyrequests` failures mid-deploy.
2. **Bandwidth and time.** Redeploying the observability stack alone re-pulls
   ~2 GB. A cache makes repeated installs and rebuilds dramatically faster.
3. **Developer laptops benefit too.** Rancher Desktop supports registry mirrors,
   so one cache on the network speeds up every `uis deploy` for everyone — not
   just production.

---

## Part 1: Findings from the reference implementation

### F1 — The cache must live OUTSIDE the cluster (architectural, not preference)

A registry running *inside* the cluster cannot serve the images required to start
that cluster. After a cold boot, the cache's own pod needs an image, which needs
the cache. Same bootstrap circularity as an in-cluster secret store.

**Implication for UIS:** a registry cache is **not a service** in the
`uis deploy <service>` sense. It belongs to the **host/platform layer** — alongside
the things UIS provisions *around* a cluster. This may need a new concept, or it
fits naturally under host/target management.

*(In-cluster P2P alternatives such as `spegel` share already-pulled layers between
nodes and are useful, but they cannot solve the cold-start case and are irrelevant
on a single-node cluster.)*

### F2 — `registry:2` proxies exactly one upstream, so N upstreams need N instances

`REGISTRY_PROXY_REMOTEURL` is singular. The reference build runs four containers:

| Port | Upstream |
|---|---|
| 5000 | `https://registry-1.docker.io` |
| 5001 | `https://registry.k8s.io` |
| 5002 | `https://ghcr.io` |
| 5003 | `https://quay.io` |

Workable but clunky. **Alternatives worth evaluating before implementing:** `zot`
(CNCF, supports multiple upstream sync targets in one instance), `Harbor` (heavy,
but full-featured with GC and auth), or `docker/distribution` behind a router.

### F3 — k3s wiring is simple and well-defined

`/etc/rancher/k3s/registries.yaml`:

```yaml
mirrors:
  docker.io:
    endpoint: ["http://<cache-host>:5000"]
  registry.k8s.io:
    endpoint: ["http://<cache-host>:5001"]
  ghcr.io:
    endpoint: ["http://<cache-host>:5002"]
  quay.io:
    endpoint: ["http://<cache-host>:5003"]
```

k3s generates `/var/lib/rancher/k3s/agent/etc/containerd/certs.d/<registry>/hosts.toml`
from this on restart. Verified: pulls route through the cache and the upstream
remains the fallback. (Rancher Desktop accepts the same file, and other distros
have equivalents — so the concept is portable across UIS's cluster types.)

### F4 — ⚠️ `crictl pull` does NOT warm the cache (the trap)

**This cost real time and produced a false positive.** `crictl pull` is a no-op
when the image is already present on the node — it never contacts the mirror.
A warming loop over all 41 images reported:

```
pulled ok=41  failed=0
```

…while the cache actually contained **4 repositories**. Confirmed by querying the
registry rather than trusting exit codes:

```bash
curl -s http://<cache>:5000/v2/_catalog
{"repositories":["library/busybox","library/postgres","library/redis"]}
```

**The reliable method is to request each image *from the mirror endpoint*,** which
forces it to fetch and store:

```bash
skopeo copy --src-tls-verify=false \
  docker://<cache-host>:5000/library/redis:7.4 dir:/tmp/warm && rm -rf /tmp/warm
```

After doing it properly: **42 repositories, ~2 GB**.

**Any `uis registry warm` implementation must verify via `/v2/_catalog`, not via
the pull command's exit status.**

### F5 — Official Docker Hub images need `library/` inserted

`docker.io/redis:7.4` maps to `<cache>:5000/library/redis:7.4`, not
`<cache>:5000/redis:7.4`. This was the single failure in the warming run. Any
image→mirror path translation needs to handle: bare name (`nginx`), `org/repo`,
and fully-qualified `docker.io/...`, `ghcr.io/...` etc.

### F6 — Outage behaviour, verified

With internet egress blocked (nft drop to everything outside the LAN) on **both**
the cache host and the cluster node, an image was deleted from the node and
pulled again successfully from cache. This is the test any implementation should
ship as its acceptance criteria — it is the only way to know the cache is real.

### F7 — Sizing and lifecycle

~2 GB for 42 repositories of a 13-service platform. Cache storage should live on
snapshotted/backed-up storage if cheap, but it is **reconstructible** — so it is
a candidate for exclusion from offsite backup.

No garbage collection is configured in the reference build. `registry:2` needs
`REGISTRY_STORAGE_DELETE_ENABLED=true` plus a periodic `registry garbage-collect`
run, or the cache grows without bound as tags churn.

---

## Part 2: Proposed plans (ordered)

```
PLAN-system-registry-cache-001-provision.md      ← the cache host/role itself
PLAN-system-registry-cache-002-cluster-wiring.md ← generate registries.yaml on provision
PLAN-system-registry-cache-003-warm-verify.md    ← `uis registry warm` + outage test
```

### PLAN-001 — Provision the cache

Decide the engine (see F2) and where it runs. Because of F1 it cannot be a
cluster service; candidates are a small VM/container on the same host, or a role
added to the host templates from
`INVESTIGATE-system-remote-deployment-targets`.

*Acceptance:* a documented, reproducible cache reachable from the cluster,
surviving host reboot.

### PLAN-002 — Wire clusters to it automatically

Render `registries.yaml` (or the distro equivalent) during cluster provisioning,
from a cache endpoint configured in `.uis.extend`. Must degrade gracefully: no
cache configured ⇒ current behaviour, unchanged.

*Acceptance:* a freshly provisioned cluster pulls through the cache with no
manual file editing; `certs.d/*/hosts.toml` is present.

### PLAN-003 — `uis registry warm` and verification

A command that enumerates images in use (or in the enabled service set) and warms
them **via the mirror endpoints** (F4), handling path translation (F5), then
reports what is actually cached from `/v2/_catalog`. Plus a documented outage test
(F6) and a GC policy (F7).

*Acceptance:* `uis registry warm` reports cached repository counts that match the
enabled services; the outage test passes.

---

## Part 3: Open questions

1. **Engine:** four `registry:2` instances, or one multi-upstream tool (`zot`)?
   Fewer moving parts is worth a lot for a self-hosted platform.
2. **Where does a non-cluster component live in the UIS model?** This is the
   interesting design question — UIS's unit of composition is an in-cluster
   service, and this cannot be one. Same shape as an external database, external
   object store, or the secret store: a growing class of "platform components
   beside the cluster" that may deserve first-class support.
3. **Private registries.** `ghcr.io` pulls of private images need credentials in
   the cache. Out of scope for a first pass, but worth designing for.
4. **TLS.** Plain HTTP is acceptable on a trusted segment (and simplest), but
   `containerd` needs explicit configuration for insecure endpoints on some
   distros. TLS with an internal CA is the cleaner end state.
5. **One cache for many clusters?** A single cache serving production, dev
   laptops and CI multiplies the benefit — but makes it a shared dependency, so
   it should fail open (upstream fallback) rather than closed.
6. **Retention/GC defaults** so the cache cannot fill the disk it shares.

---

## Appendix: reference implementation as built

Proxmox LXC (2 cores, 1 GB RAM, 60 GB cache volume on ZFS with 1 M recordsize +
zstd), Docker running four `registry:2` pull-through caches with
`--restart=always`, cluster wired via `registries.yaml`. Warmed with `skopeo` to
42 repositories / ~2 GB. Outage-tested by blocking egress on both the cache and
the cluster node. Cache volume is snapshotted and included in guest backups,
though it is fully reconstructible.
