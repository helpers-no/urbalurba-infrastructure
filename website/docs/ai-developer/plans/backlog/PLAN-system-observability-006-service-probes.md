# Ship an availability probe with every service

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: `uis deploy <service>` results in that service being monitored by the
external watchdog, with **no configuration written by the user**.

**Last Updated**: 2026-08-08

**Investigations**:
- [INVESTIGATE-system-monitor-definitions-with-services](./INVESTIGATE-system-monitor-definitions-with-services.md) — asked the question this answers
- [INVESTIGATE-service-uptime-kuma](./INVESTIGATE-service-uptime-kuma.md) — established the external watchdog

**Prerequisites**: `PLAN-system-observability-003-service-dashboards` establishes
the per-service artifact mechanism. This adds a third artifact to it rather than
inventing a parallel one.

**Priority**: Medium

---

## Problem

After `PLAN-003`, `uis deploy postgresql` yields a Grafana dashboard with no
manual steps — but **no availability probe**. The signal answering *"why is it
slow?"* is automated; the signal answering *"is it up?"* stays manual.

And the gap is invisible. A missing dashboard is obvious the moment someone
looks for it. A monitor that was never created is indistinguishable from one
that is passing: **absence renders as green**.

The reference deployment has 19 hand-written monitors encoding knowledge every
other installation would otherwise rediscover the hard way — *a sealed vault
answers 503*, *LiteLLM returns 200 with a dead database*, *Grafana's health
endpoint needs a keyword*.

## What makes this cheap

Both halves a monitor needs are **already known to UIS**:

| Needed | Where it already is |
|---|---|
| *How* to probe — path, keyword, which secret | knowledge about the service → **ships with the service** |
| *Where* the service is | the `Service` and `Ingress` UIS created → **discovered** |

Verified on the reference deployment with nothing hand-written:

```
k8s Service      → litellm.ai.svc.cluster.local:4000
IngressRoute     → HostRegexp(`litellm\..+`)
tailnet Ingress  → litellm.taile269d.ts.net
```

⚠️ **Never ask the user for endpoints.** An earlier draft had the operator
maintain a file of hostnames. That defeats the point of UIS: you run
`uis deploy` and should not need to know how the thing is wired.

---

## Transport: AutoKuma's static file source

Uptime Kuma has no official REST API (one is reportedly in development). Its
Socket.IO interface is documented but **explicitly unsupported — "breaking
changes may occur between versions without prior notice"**.

Three options were weighed:

| | Verdict |
|---|---|
| Write to Kuma's SQLite directly | ✗ Works with a pinned version, but reimplements the app. The reference implementation already had to replicate `updateMonitorNotification` and `startMonitor`, and skipped `bean.validate()`. Every gap found was a gap that had to be re-found. |
| Call Socket.IO ourselves | ✗ Same version coupling, and UIS would own a client for an unsupported interface |
| **[AutoKuma](https://github.com/BigBoot/AutoKuma) static file source** | ✓ **Chosen** |

AutoKuma is the established community answer for infrastructure-as-code with
Uptime Kuma. UIS writes files; AutoKuma reconciles them over Socket.IO.

**What this buys:**

- UIS never touches the database, the Socket.IO API, or Kuma's version
- Notification linkage, monitor start and validation are AutoKuma's problem
- `AUTOKUMA__ON_DELETE=delete` (with `AUTOKUMA__DELETE_GRACE_PERIOD`) removes
  monitors when their file disappears — the `uis undeploy` orphan problem is
  solved by the tool rather than by us
- When the official API lands, AutoKuma adopts it and UIS changes nothing

⚠️ **Use the file source, not the Kubernetes source.** AutoKuma's Kubernetes and
Docker Swarm providers are supported "on an as-is basis… basically looking for a
maintainer". The file source has no such caveat.

### The interface is a ConfigMap

```
uis monitors apply
      │  renders one .json per monitor
      ▼
ConfigMap  uptime-kuma-monitors          ← the only thing UIS writes
      │  mounted at AUTOKUMA__STATIC_MONITORS
      ▼
AutoKuma  (sidecar next to Uptime Kuma)
      │  Socket.IO
      ▼
Uptime Kuma
```

A key added to the ConfigMap creates a monitor; a key removed deletes one. That
is the whole contract, and it is entirely within Kubernetes primitives UIS
already uses.

---

## Phase 1: The probe artifact

### Tasks

- [ ] 1.1 Define the `probes` artifact alongside `dashboard` and `alerts` from
      PLAN-003 — one observability contract per service, not two
- [ ] 1.2 Fields: `type`, `path` (relative — never a hostname), `keyword`,
      `accepted_statuscodes`, `ignore_tls`, `interval`, `maxretries`, and
      `auth: <secret_key_name>` naming a key in `urbalurba-secrets`, never a value
- [ ] 1.3 `probes/litellm.yaml` — worked example for keyword matching *(done)*
- [ ] 1.4 `probes/postgresql.yaml` — worked example for a TCP probe **through the
      Service**, which is what makes externalised state work *(done)*

### Validation

Both files parse; neither contains a hostname or a secret value.

---

## Phase 2: Render

### Tasks

- [ ] 2.1 Enumerate deployed services from the service registry
- [ ] 2.2 Resolve reachability: the `Service` for in-cluster, the
      `Ingress`/`IngressRoute` for the external hostname the watchdog needs
- [ ] 2.3 Resolve `auth:` by reading the named key from `urbalurba-secrets`
- [ ] 2.4 Render each probe to AutoKuma's monitor JSON schema
- [ ] 2.5 Write them into the `uptime-kuma-monitors` ConfigMap, one key per monitor

### Validation

```bash
uis monitors render     # prints exactly what would be written, applies nothing
```

Output for a service the user never configured matches what a human would have
written by hand.

---

## Phase 3: Deploy AutoKuma with the watchdog

### Tasks

- [ ] 3.1 Add AutoKuma as a second container in the `uptime-kuma` StatefulSet —
      it needs no storage of its own and shares the pod's lifecycle
- [ ] 3.2 Mount the `uptime-kuma-monitors` ConfigMap at `AUTOKUMA__STATIC_MONITORS`
- [ ] 3.3 Authenticate with `AUTOKUMA__KUMA__USERNAME` / `..._PASSWORD` from
      `urbalurba-secrets` — the same `uptime-kuma-admin-*` keys the setup
      playbook already seeds, so no new credential
- [ ] 3.4 Set `AUTOKUMA__ON_DELETE=delete` with a grace period
- [ ] 3.5 Pin the AutoKuma image, as with every other image

### Validation

```bash
kubectl logs -n monitoring uptime-kuma-0 -c autokuma   # connected, monitors synced
```

A monitor appears in Uptime Kuma without anyone opening the UI.

---

## Phase 4: Lifecycle

### Tasks

- [ ] 4.1 `uis deploy <service>` adds its probe to the ConfigMap
- [ ] 4.2 `uis undeploy <service>` removes it — AutoKuma then deletes the monitor
- [ ] 4.3 `uis monitors check` — compare intended against the ConfigMap **and**
      against what Kuma is running, so a wedged AutoKuma is visible. Reconcilers
      fail silently; that is the same absence-renders-as-green trap
- [ ] 4.4 Optional `.uis.extend/monitors.yaml` for targets UIS did not deploy —
      a hypervisor, a NAS, machines outside the cluster, job heartbeats. **Empty
      or absent on a stock install.**

### Validation

```bash
uis deploy redis && uis monitors check     # monitor exists in Kuma
uis undeploy redis && uis monitors check   # gone, no orphan
```

---

## Acceptance Criteria

- [ ] `uis deploy <service>` on a cluster with the watchdog yields a monitor,
      with **zero user configuration**
- [ ] No endpoint or hostname is ever written by the user
- [ ] `uis undeploy <service>` removes the monitor
- [ ] UIS writes only a ConfigMap — never Kuma's database or Socket.IO API
- [ ] `uis monitors check` detects a stalled AutoKuma, not just missing files
- [ ] Probe definitions contain secret *names*, never values
- [ ] A stock install needs no `.uis.extend/monitors.yaml`

---

## Implementation Notes

**Probe through the Service, not the container.** On the reference deployment
PostgreSQL runs *outside* the cluster behind a shim Service. Probing
`postgresql.default:5432` tests the whole path — shim, network, external
container — which is what Temporal and Authentik actually depend on. Probing the
database host directly would stay green while that path was broken. It also
means installations that externalise state need no special handling: UIS sees an
ordinary Service either way.

**Why not keep the direct-to-database reconciler.** The reference deployment has
a working one, and it was tempting to promote it. Reading Kuma's own `add`
handler settled it: creating a monitor also calls `updateMonitorNotification`
(the `monitor_notification` join table — without it a monitor pages nobody),
`startMonitor`, and `bean.validate()`. A raw insert had already missed two of
those. Pinning the version makes the *schema* knowable, as it should — but the
work is reimplementing the application, not reading its tables.

**Retain the drift check.** AutoKuma reconciles continuously, so drift
self-heals — which means a *stopped* AutoKuma looks exactly like a healthy one.
Phase 4.3 exists for that, and the reference implementation's `--check` already
does the comparison.

**Credentials already exist.** `PLAN-service-uptime-kuma` seeds
`uptime-kuma-admin-user` / `uptime-kuma-admin-password` into `urbalurba-secrets`,
inheriting `DEFAULT_ADMIN_PASSWORD`. AutoKuma authenticates with the same pair —
no new secret, nothing extra to rotate.

---

## Files to Modify

- `provision-host/uis/services/<category>/probes/<id>.yaml` (new, per service)
- `provision-host/uis/manage/uis-monitors.sh` (new)
- `provision-host/uis/manage/uis-cli.sh` — register the `monitors` verb
- `manifests/230-uptime-kuma-statefulset.yaml` — add the AutoKuma container
- `ansible/playbooks/230-setup-uptime-kuma.yml` — create the ConfigMap
- `PLAN-system-observability-003-service-dashboards.md` — extend to three artifacts
- the service-authoring guide — document the `probes` artifact
