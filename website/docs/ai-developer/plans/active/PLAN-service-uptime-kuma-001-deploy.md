# Deploy Uptime Kuma as an external watchdog

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Active — Phases 1 & 2 done, Phase 3 pending first-run setup

**Goal**: Run Uptime Kuma on a host outside the monitored platform, with its
database on storage whose failure does not cost a rebuild.

**Investigation**: [INVESTIGATE-service-uptime-kuma.md](./INVESTIGATE-service-uptime-kuma.md)

**Priority**: High

**Last Updated**: 2026-08-07

**Deployed**: 2026-08-07 on `assist` k3s, namespace `monitoring`

---

## Problem

Six incidents in one week went unnoticed until a human asked (investigation F1),
including a pipeline stopped for 8.4 hours and a database replica that reported
"healthy" for 82 days after its primary ceased to exist. The in-cluster stack
cannot close this gap because it dies with the thing it watches (F3).

## Solution

Uptime Kuma on `assist` — a Raspberry Pi that is not part of the monitored
platform. It already runs Home Assistant, Z-Wave JS and a small k3s, so this is
an addition to an existing light server, not a new one.

**Target: the k3s on assist**, not Docker, so the deployment is declarative and
reviewable alongside everything else.

---

## Phase 1: Storage and namespace

### Tasks

- [x] 1.1 Create namespace `monitoring` on assist's k3s ✓
- [x] 1.2 ⚠️ **`local-path-usb` turned out to be broken** — see below. Used a
      **static PV** instead (`uptime-kuma-usb`, 4Gi, `Retain`) ✓
- [x] 1.3 PVC Bound to `/mnt/hadata/k3s-storage/uptime-kuma` ✓

### ⚠️ Finding: the `local-path-usb` StorageClass does not work for new claims

It declares `parameters.nodePath=/mnt/hadata/k3s-storage`, which **this version
of the k3s local-path-provisioner ignores**. The provisioner only honours the
`nodePathMap` in the `local-path-config` ConfigMap, which lists just the boot
microSD. New claims fail with:

```
failed to provision volume with StorageClass "local-path-usb":
config doesn't contain path /mnt/hadata/k3s-storage on node assist
```

MinIO's volume predates this and still works, so **the class looks functional
until you try to use it**. Editing `local-path-config` would fix it until the
next k3s upgrade, which rewrites that ConfigMap.

Resolved with a static PV pinned by `nodeAffinity` — no provisioner dependency,
survives upgrades. Anything else on this cluster wanting USB-backed storage will
hit the same wall.

### Validation

```bash
kubectl get pvc -n monitoring uptime-kuma -o wide   # Bound, local-path-usb
```

Rationale: the USB stick is **slower** than the boot card (measured: 6.9 vs
33.3 MB/s sequential; 136 vs 155 sync-writes/sec — investigation F7). It is used
for **blast radius**, not speed: wearing it out costs a stick, not the OS.

---

## Phase 2: Deploy

### Tasks

- [x] 2.1 Deployment `uptime-kuma`, image pinned to a specific version — **not
      `:latest`**, per the version-pinning lesson from
      `PLAN-service-litellm-002-version-pinning.md`
- [x] 2.2 Mount the PVC at `/app/data`
- [x] 2.3 `strategy: Recreate` — SQLite on RWO must not have two writers
- [x] 2.4 Resource requests/limits (~200Mi/512Mi) so it cannot starve Home Assistant
- [x] 2.5 Liveness/readiness probes on `/` (port 3001)
- [x] 2.6 Service + Ingress via the traefik already running on assist

### Validation

```bash
kubectl rollout status deploy/uptime-kuma -n monitoring
curl -s -o /dev/null -w '%{http_code}\n' http://<assist>/   # 200 or 302
```

Verified 2026-08-07:

```
http://127.0.0.1/       302   (localhost)
http://192.168.68.79/   302   (LAN)
http://100.83.51.125/   302   (tailnet)
follow -> /setup-database  200  <title>Uptime Kuma</title>
```

Image `louislam/uptime-kuma:2.5.0` (arm64 verified before pinning). Ready ~90s
after the image pull completed.

⏳ **Outstanding**: the v2 first-run wizard (`/setup-database` → choose SQLite,
then create the admin account) is browser-only and has not been completed.
Phase 3 cannot start until it is.

---

## Phase 3: Tune for flash storage

### Tasks

- [ ] 3.1 Default check interval **60s**, not 20s
- [ ] 3.2 Retention trimmed (~30 days) rather than the default
- [ ] 3.3 After a week, record DB size and growth rate in this plan

### Validation

```bash
kubectl exec -n monitoring deploy/uptime-kuma -- du -sh /app/data
```

User confirms growth is linear and modest.

---

## Acceptance Criteria

- [x] Uptime Kuma reachable from the LAN and the tailnet
- [x] Data on the USB stick, **not** the boot microSD (static PV)
- [x] Image pinned to `2.5.0`
- [ ] Survives a reboot of assist with monitors intact
- [ ] Does not disturb Home Assistant or Z-Wave JS
- [x] Deployed declaratively; manifest at `hosts/assist/uptime-kuma.yaml`

---

## Implementation Notes

⚠️ **It must never be deployed to asgard or Odin.** That would reintroduce
exactly the blind spot it exists to remove (investigation F3). If UIS later gains
a service definition for it, that definition must carry the same warning.

Housekeeping done 2026-08-07: the orphaned `pg-replica` (replicating from the
now-dead iMac, reporting "healthy" for 82 days) and the then-unused
`cnpg-cloudnative-pg` operator were both removed, along with 10 leftover CRDs.

⚠️ **Gap noticed and not addressed**: nothing backs up `assist` itself. It now
holds this watchdog, the operator documentation, and the rescue copy of the
iMac. Worth its own plan.

---

## Files to Modify

- new manifest for the assist deployment (namespace, PVC, Deployment, Service, Ingress)
