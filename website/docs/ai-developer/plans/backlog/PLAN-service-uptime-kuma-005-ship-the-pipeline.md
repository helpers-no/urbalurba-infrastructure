# Ship the monitor pipeline as part of the service

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Active — Phases 1–4 done and the reference installation migrated; auto-discovery is single-cluster only

**Goal**: `uis deploy uptime-kuma` gives a watchdog that is **already monitoring
and already alerting**, rebuildable from nothing, with the only
installation-specific input being a list of targets UIS did not deploy.

**Last Updated**: 2026-08-09

**Prerequisites**: [PLAN-service-uptime-kuma-004-uis-service](../completed/PLAN-service-uptime-kuma-004-uis-service.md) *(done)*

**Related**:
- [PLAN-service-uptime-kuma-002-monitors](../active/PLAN-service-uptime-kuma-002-monitors.md) — what to watch, proven on the reference installation
- [PLAN-service-uptime-kuma-003-alerting](./PLAN-service-uptime-kuma-003-alerting.md) — the alerting design this ships
- [PLAN-system-observability-006-service-probes](./PLAN-system-observability-006-service-probes.md) — **depends on this.** 006 auto-generates probes per service; it needs the pipeline this plan ships to deliver them

**Priority**: High

---

## Problem

Uptime Kuma is a UIS service: `uis deploy uptime-kuma` installs it, seeds the
admin account, needs no browser wizard, and `--purge` removes it cleanly.

**Everything that makes it useful is still hand-built.** On the reference
installation the monitors, the reconciler, the alert channel and the heartbeat
wiring live in a private ops repo and were assembled by hand. A second
installation gets an empty watchdog and a blank page.

That is the gap between *a service that installs* and *a service that works*.

The pieces are all proven — 19 monitors, 16 paging a phone, four backup
heartbeats wired, verified through two complete purge-and-rebuild cycles. None of
them are in the product.

## The boundary this plan holds

| | Ships in UIS | Stays installation-specific |
|---|---|---|
| AutoKuma, its manifest and quirks | ✅ | |
| `uis monitors` render / apply / check | ✅ | |
| Notification channel wiring | ✅ | |
| Heartbeat token derivation | ✅ | |
| *Which* hosts, *which* addresses | | ✅ `.uis.extend/monitors.yaml` |
| Secrets (topic, salt, auth headers) | | ✅ `urbalurba-secrets` |

⚠️ **Never ask the user for an endpoint UIS already knows.** Targets UIS deployed
are discovered. The extend file is only for things UIS did **not** deploy — a
hypervisor, a NAS, a laptop, a job heartbeat. It is empty on a stock install.

---

## Phase 1: AutoKuma ships with the service

Six behaviours were found the hard way on the reference installation, and
**every one fails silently**. The manifest must encode all six or the next person
rediscovers them.

### Tasks

- [x] 1.1 `manifests/230-uptime-kuma-autokuma.yaml` — a **separate Deployment**,
      not a sidecar. Containers in a pod start together, Kuma needs ~30s before
      it accepts Socket.IO, and AutoKuma makes one connect attempt and never
      retries. Its own Deployment makes the restart loop the retry
- [x] 1.2 `strategy: Recreate`. `/data` is RWO with a lock-protected store;
      RollingUpdate runs two instances, and because files are copied into an
      `emptyDir` the two can work from **different file sets**
- [x] 1.3 A **PVC for `/data`** — AutoKuma's id→entity map. Without it every
      restart re-creates every monitor: one restart took 19 monitors to 38
- [x] 1.4 An init container that **flattens the Secret with `cp -L`** into an
      `emptyDir`. Kubernetes mounts Secrets as symlinks into `..data/`, which
      AutoKuma's file scanner does not follow — it syncs nothing and logs nothing
- [x] 1.5 A `wait-for-kuma` init container against the Service, not localhost
- [x] 1.6 Pin the image to `2.0.0` — **not** `v2.0.0`, which is single-arch and
      will not pull on arm64
- [x] 1.7 `AUTOKUMA__ON_DELETE=delete` with a grace period, so removing a
      definition removes the monitor

### Validation

```bash
kubectl rollout restart deployment/autokuma -n monitoring
# monitor count MUST be unchanged - this is the /data regression test
```

---

## Phase 2: `uis monitors`

### Tasks

- [x] 2.1 `uis monitors render` — print what would be written, change nothing
- [x] 2.2 `uis monitors apply` — render into the `uptime-kuma-monitors` Secret
- [x] 2.3 `uis monitors check` — compare intended against the Secret **and**
      against what Kuma is running. AutoKuma self-heals drift, so a *stopped*
      AutoKuma looks exactly like a healthy one
- [x] 2.4 Heartbeat tokens derived as `HMAC-SHA256(salt, monitor name)` from
      `uptime-kuma-push-salt` in `urbalurba-secrets`. **Not random**: a rebuild
      must reissue identical URLs or every job needs rewiring, and the old URL
      goes quietly silent rather than failing loudly
- [x] 2.5 Emit `push_token` explicitly — AutoKuma does not generate one, and a
      push monitor without a token has no callable URL and can never go UP

### Validation

```bash
uis monitors apply && uis monitors check     # clean
uis undeploy uptime-kuma --purge && uis deploy uptime-kuma && uis monitors apply
uis monitors check                            # still clean, same push URLs
```

---

## Phase 3: Targets UIS did not deploy

### Tasks

- [x] 3.1 Read `.uis.extend/monitors.yaml` if present. Absent is normal
- [x] 3.2 Schema: `name`, `type` (`http`/`port`/`push`), `url`/`hostname`+`port`,
      `keyword`, `accepted_statuscodes`, `ignore_tls`, `interval`, `maxretries`,
      `notify`, and `auth_header_secret` naming a key in `urbalurba-secrets` —
      **never a secret value**
- [x] 3.3 Require a `why:` per entry ✓ — render fails if any entry lacks one.
      A monitor nobody can justify is a monitor nobody maintains, and when it
      goes red the first question is "what breaks if I ignore this?"
- [ ] 3.4 Document it with the reference installation's file as the worked
      example

### Validation

A stock install has no such file and behaves identically.

---

## Phase 4: Alerting that is on by default

An installed watchdog that notifies nobody is a dashboard. This is the phase that
makes it a watchdog.

### Tasks

- [x] 4.1 Seed the notification channel from `urbalurba-secrets`
      (`uptime-kuma-ntfy-server`, `uptime-kuma-ntfy-topic`). Absent ⇒ skip
      cleanly with a warning, never fail the deploy
- [x] 4.2 Attach it to every monitor with `notify: true` (the default)
- [x] 4.3 ⚠️ **Do not let AutoKuma own the channel.** It can — a file with
      `"type": "notification"` is accepted and delivers correctly — but AutoKuma
      2.0.0 never converges on notifications, rewriting it every ~5s forever.
      Confirmed with a single instance and a cleared state store
- [x] 4.4 Consequence of 4.3: `notification_name_list` must **not** appear in
      rendered monitor files, or AutoKuma logs a resolve warning per monitor per
      pass
- [x] 4.5 Seed retention (`keepDataPeriodDays`) — already shipped, keep it

### Validation

Deliberately fail a monitor; a notification arrives on a real device.

---

## Phase 5: Prove it on the reference installation

The point of the whole plan: the hand-built installation is replaced by the
shipped one, and nothing is lost.

### Tasks

- [x] 5.1 Move the 19 monitors into `.uis.extend/monitors.yaml`
- [x] 5.2 Move salt, ntfy topic and auth headers into `urbalurba-secrets`,
      sourced from OpenBao where they already live
- [x] 5.3 `uis undeploy uptime-kuma --purge`, redeploy, `uis monitors apply`
- [x] 5.4 Confirm: same 19 monitors, **same push URLs** (so no job needs
      rewiring), same 16 paging, alert delivery still verified
- [ ] 5.5 Retire the hand-built reconciler in the ops repo, leaving only the
      installation-specific YAML and secrets

### Validation

```bash
uis monitors check     # identical to before the rebuild
```

The ops repo keeps no code — only intent.

---

## Acceptance Criteria

- [ ] `uis deploy uptime-kuma` on a fresh cluster monitors and alerts with no
      hand-written Kubernetes and no clicking in the UI
- [ ] A stock install needs no `.uis.extend/monitors.yaml`
- [ ] Restarting AutoKuma never changes the monitor count
- [ ] A purge-and-rebuild reissues **identical** heartbeat URLs
- [ ] Definitions carry secret *names*, never values
- [ ] `uis monitors check` detects a stalled AutoKuma, not just missing files
- [ ] The reference installation runs entirely on the shipped pipeline

---

## Cross-cluster: `--from` and `--to`

*Resolved 2026-08-09.* `uis monitors` reads services from one cluster and writes
definitions into another:

```bash
uis monitors apply --from asgard --to assist
```

`--from` is where the services are (read-only). `--to` is where Uptime Kuma runs.
Omit both for a single-cluster developer setup; the topology is then detected by
looking for the watchdog in the discovered cluster.

⚠️ **Least privilege, not an admin kubeconfig.** Discovery needs three read verbs
on services, endpoints and ingresses — nothing more. `manifests/230-uptime-kuma-
discovery-rbac.yaml` creates a `monitor-discovery` ServiceAccount for exactly
that. Copying a cluster-admin kubeconfig onto the watchdog would put full control
of the platform on the machine whose entire purpose is to sit outside it — on the
reference installation, a Raspberry Pi running from a microSD card. Verified: the
identity can list services and cannot read secrets or delete anything.

### Still to do

- [x] Persist the context pair per installation ✓ —
      `MONITORS_FROM_CONTEXT` / `MONITORS_TO_CONTEXT` in
      `.uis.extend/cluster-config.sh`, so `uis monitors check` needs no flags.
      Explicit flags still win. This mattered: a `check` run with the wrong
      contexts reports confident, entirely spurious drift

## Implementation Notes

**Why AutoKuma rather than writing to the database.** Uptime Kuma has no official
REST API and its Socket.IO interface is explicitly unsupported. The reference
implementation *did* write to SQLite successfully — but creating a monitor
properly also means `updateMonitorNotification`, `startMonitor` and
`bean.validate()`, and each gap had to be found the hard way. AutoKuma is the
community's answer and absorbs that maintenance.

**Where the database is still touched.** Two places, both deliberate and both
narrow: the admin account seed (Kuma has no other way to create the first user)
and the notification channel plus its attachments (see 4.3). Both are guarded —
schema is checked first, and inserts never update or delete.

**Retain the drift check.** A reconciler that stops looks exactly like one with
nothing to do. That is *absence renders as green* applied to the tool meant to
prevent it, which is why 2.3 compares against Kuma and not just the Secret.

**The extend file is not the endpoint list.** An earlier draft had the operator
maintain hostnames for everything. It was rejected: UIS knows where the things it
deployed are. External dependencies should become shim Services
([PLAN-system-dependencies-shim-services](./PLAN-system-dependencies-shim-services.md))
and be discovered like anything else — leaving the extend file for hypervisors,
NAS boxes and job heartbeats only.

---

## Files to Modify

- `manifests/230-autokuma-deployment.yaml` (new)
- `ansible/playbooks/230-setup-uptime-kuma.yml` — deploy AutoKuma, seed the channel
- `provision-host/uis/manage/uis-monitors.sh` (new)
- `provision-host/uis/manage/uis-cli.sh` — register the `monitors` verb
- `provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template`
  — `uptime-kuma-push-salt`, `uptime-kuma-ntfy-server`, `uptime-kuma-ntfy-topic`
- `website/docs/services/observability/uptime-kuma.md`
