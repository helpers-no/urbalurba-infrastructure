# Deploy Uptime Kuma as an external watchdog

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: Run Uptime Kuma on a host outside the monitored platform, with its
database on storage whose failure does not cost a rebuild.

**Investigation**: [INVESTIGATE-service-uptime-kuma.md](./INVESTIGATE-service-uptime-kuma.md)

**Priority**: High

**Last Updated**: 2026-08-07

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

- [ ] 1.1 Create namespace `monitoring` on assist's k3s
- [ ] 1.2 Create a PVC using the **`local-path-usb`** StorageClass (not the
      default `local-path`, which is the boot microSD). Size 4Gi — the DB is
      small; the constraint is write volume, not capacity
- [ ] 1.3 Confirm the PVC binds to a path under `/mnt/hadata`

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

- [ ] 2.1 Deployment `uptime-kuma`, image pinned to a specific version — **not
      `:latest`**, per the version-pinning lesson from
      `PLAN-service-litellm-002-version-pinning.md`
- [ ] 2.2 Mount the PVC at `/app/data`
- [ ] 2.3 `strategy: Recreate` — SQLite on RWO must not have two writers
- [ ] 2.4 Resource requests/limits (~200Mi/512Mi) so it cannot starve Home Assistant
- [ ] 2.5 Liveness/readiness probes on `/` (port 3001)
- [ ] 2.6 Service + Ingress via the traefik already running on assist

### Validation

```bash
kubectl rollout status deploy/uptime-kuma -n monitoring
curl -s -o /dev/null -w '%{http_code}\n' http://<assist>/   # 200 or 302
```

User confirms the UI loads and the admin account can be created.

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

- [ ] Uptime Kuma reachable from the LAN and the tailnet
- [ ] Database on `local-path-usb`, **not** on the boot microSD
- [ ] Image pinned to an explicit version
- [ ] Survives a reboot of assist with monitors intact
- [ ] Does not disturb Home Assistant or Z-Wave JS
- [ ] Deployed declaratively; the manifest is committed

---

## Implementation Notes

⚠️ **It must never be deployed to asgard or Odin.** That would reintroduce
exactly the blind spot it exists to remove (investigation F3). If UIS later gains
a service definition for it, that definition must carry the same warning.

Housekeeping found while surveying assist: the **`cnpg-cloudnative-pg` operator
in `cnpg-system` is now unused** — its only consumer, the orphaned `pg-replica`,
was removed on 2026-08-07. Removing it frees memory on the same box.

---

## Files to Modify

- new manifest for the assist deployment (namespace, PVC, Deployment, Service, Ingress)
