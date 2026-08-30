# Deploy Uptime Kuma as an external watchdog

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Active — goal met; retention tuning (3.2) is all that remains

⚠️ **Phases 1 and 2 were superseded on 2026-08-08.** The hand-written manifest
they describe was removed and replaced by the UIS service definition in
[PLAN-service-uptime-kuma-004-uis-service](../completed/PLAN-service-uptime-kuma-004-uis-service.md)
(completed), at the user's direction: *"Remove the hand written service and use
the uis command to deploy."* Their findings are kept below because they are still
true and still cost real time to rediscover; the specific resources they created
no longer exist.

The first-run wizard that blocked Phase 3 is **gone** — the account is seeded by
the setup playbook and there is no browser step.

**Goal**: Run Uptime Kuma on a host outside the monitored platform, with its
database on storage whose failure does not cost a rebuild.

**Investigation**: [INVESTIGATE-service-uptime-kuma.md](../backlog/INVESTIGATE-service-uptime-kuma.md)

**Priority**: High

**Last Updated**: 2026-08-08

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

Resolved at the time with a static PV pinned by `nodeAffinity`.

**Superseded 2026-08-08 by a better fix.** The static PV solved it for this one
volume and left the trap in place for everything else. The durable fix is a k3s
server flag in `/etc/rancher/k3s/config.yaml` on assist:

```yaml
default-local-storage-path: /mnt/hadata/k3s-storage
```

The default `local-path` StorageClass now provisions onto the USB stick, so
**every** claim on this cluster lands there without asking — no static PV, no
`local-path-usb`, nothing per-volume to remember. The static PV was deleted.

Verified after a full purge-and-rebuild on 2026-08-08 — both the Kuma and
AutoKuma volumes provisioned to `/dev/sda1` (the USB stick):

```
/mnt/hadata/k3s-storage/pvc-…_monitoring_uptime-kuma-data   /dev/sda1
/mnt/hadata/k3s-storage/pvc-…_monitoring_autokuma-data      /dev/sda1
```

That the fresh claims landed on USB *by default* is the point: the previous
arrangement would have silently put a rebuilt volume back on the microSD.
`minio` still uses the old `local-path-usb` class and still works, which is why
that class looks functional until you try to make a new claim with it.

### Validation

```bash
kubectl get pvc -n monitoring uptime-kuma-data -o wide   # Bound, local-path
# then confirm it is really on the stick, not just named as if it were:
kubectl get pv <name> -o jsonpath='{.spec.local.path}' | xargs df -h
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

✅ **The first-run wizard is gone (2026-08-08).** It was browser-only, which made
the whole deployment non-reproducible from the CLI. Removed in two parts, both in
the UIS service:

- `UPTIME_KUMA_DB_TYPE=sqlite` skips `/setup-database`
- the setup playbook seeds the admin row directly (bcrypt, 10 rounds), using
  `uptime-kuma-admin-user` / `uptime-kuma-admin-password` from
  `urbalurba-secrets`, which inherit `DEFAULT_ADMIN_PASSWORD`

⚠️ The seeding step reported success while creating an account with an **empty
username** — `$KUMA_USER` was inside a single-quoted `sh -c` and never expanded.
The playbook now passes the value on stdin via a heredoc, and task 11.1 verifies
the seeded credential actually authenticates (bcrypt `compareSync`) rather than
trusting that the insert ran.

**A resource existing is not the same as it working.** That is the same shape as
this plan's `local-path-usb` finding and as the empty push tokens found in
PLAN-006 — three instances in one service.

Also superseded: this is now a **StatefulSet**, not a Deployment, so `strategy:
Recreate` in 2.3 is moot — a StatefulSet with one replica cannot double-write
SQLite.

---

## Phase 3: Tune for flash storage

### Tasks

- [x] 3.1 Default check interval **60s**, not 20s ✓ — `defaults.interval: 60` in
      `monitors.yaml`. Intervals in use: 60s (services), 900s (the enrichment
      heartbeat), 93600s (the daily backup heartbeats)
- [ ] 3.2 Retention trimmed (~30 days) rather than the default — **NOT DONE**.
      `keepDataPeriodDays` is unset, i.e. Kuma's default of 180 days
- [ ] 3.3 After a week, record DB size and growth rate — **not yet measurable**

### Validation

```bash
kubectl exec -n monitoring uptime-kuma-0 -- du -sh /app/data
```

**2026-08-08: 2.8 MB.** Not a useful baseline — the database was purged and
rebuilt the same day, so this is one day of 14 monitors at 60s with no history
behind it. Re-measure after a week of uninterrupted running.

⚠️ **3.2 must be set by the playbook, not in the UI.** Retention lives in Kuma's
`setting` table, so a value clicked in through the browser is destroyed by
`uis undeploy --purge` — the same non-reproducibility the first-run wizard had.
Seed it alongside the admin account.

---

## Acceptance Criteria

- [x] Uptime Kuma reachable from the LAN and the tailnet
- [x] Data on the USB stick, **not** the boot microSD — now by k3s default rather
      than a static PV, and re-verified after a full rebuild
- [x] Image pinned to `2.5.0`
- [ ] Survives a reboot of assist with monitors intact — **not tested.** A purge
      and rebuild has been verified, which is a harder test of *reproducibility*
      but not the same thing as surviving a reboot with state intact
- [x] Does not disturb Home Assistant or Z-Wave JS — both still running; the
      `home-assistant` monitor has been UP throughout
- [x] Deployed declaratively — **as a UIS service**, `uis deploy uptime-kuma`.
      The `hosts/assist/uptime-kuma.yaml` manifest this originally specified was
      deleted; see PLAN-004
- [x] Reproducible from nothing: `uis undeploy uptime-kuma --purge` followed by
      `uis deploy uptime-kuma` rebuilds it with the admin account seeded and no
      browser step. Verified twice on 2026-08-08

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

Superseded — the work landed as a UIS service rather than a standalone manifest:

- `provision-host/uis/services/observability/service-uptime-kuma.sh`
- `ansible/playbooks/230-setup-uptime-kuma.yml` (deploy + seed the admin account)
- `ansible/playbooks/230-remove-uptime-kuma.yml` (honours `--purge`)
- `manifests/230-uptime-kuma-*.yaml`
- `provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template`
  — `uptime-kuma-admin-user` / `uptime-kuma-admin-password`
- `/etc/rancher/k3s/config.yaml` on assist — `default-local-storage-path`
  (installation config, not the product repo)

Still to do for 3.2: seed `keepDataPeriodDays` in `230-setup-uptime-kuma.yml`.
