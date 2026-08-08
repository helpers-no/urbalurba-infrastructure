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

### The interface is a Secret

```
uis monitors apply
      │  renders one .json per monitor
      ▼
Secret  uptime-kuma-monitors             ← the only thing UIS writes
      │  mounted, then flattened with `cp -L` into an emptyDir
      ▼                                    (Kubernetes mounts it as symlinks
AutoKuma  (its own Deployment, PVC on /data)  AutoKuma will not follow)
      │  Socket.IO
      ▼
Uptime Kuma
```

A key added creates a monitor; a key removed deletes one. That is the whole
contract, and it is entirely within Kubernetes primitives UIS already uses.

A Secret rather than a ConfigMap because a rendered probe can carry a resolved
`Authorization` header. The two indirections — flatten, and the PVC — are not
design choices; they are worked around because AutoKuma fails silently without
them. See Phase 3.

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
- [ ] 2.5 Write them into the `uptime-kuma-monitors` Secret, one key per monitor

### Validation

```bash
uis monitors render     # prints exactly what would be written, applies nothing
```

Output for a service the user never configured matches what a human would have
written by hand.

---

## Phase 3: Deploy AutoKuma with the watchdog

### Tasks

⚠️ **This phase was prototyped on the reference installation 2026-08-08. Four
things in the original draft were wrong, and every one of them failed silently.**
The tasks below are corrected; the reasoning is in Implementation Notes.

- [ ] 3.1 Deploy AutoKuma as its **own Deployment**, not a sidecar. Both
      containers in a pod start together, Kuma needs ~30s before it accepts
      Socket.IO, and AutoKuma makes **one** connect attempt and then never
      retries. As a separate Deployment it targets the Service and the restart
      loop is the retry
- [ ] 3.2 Give it a **PVC for `/data`**. It holds AutoKuma's id → monitor
      mapping. The original draft said "needs no storage of its own" — without
      it, every restart re-creates every monitor as a new one
- [ ] 3.3 Mount the monitor definitions, then **copy them to a plain directory
      with an init container** (`cp -L` into an `emptyDir`). Kubernetes presents
      a Secret/ConfigMap as symlinks into a hidden `..data/`, and AutoKuma's file
      scanner does not follow them
- [ ] 3.4 Use a **Secret, not a ConfigMap** — a rendered probe can carry a
      resolved `Authorization` header
- [ ] 3.5 Authenticate with `AUTOKUMA__KUMA__USERNAME` / `..._PASSWORD` from
      `urbalurba-secrets` — the same `uptime-kuma-admin-*` keys the setup
      playbook already seeds, so no new credential
- [ ] 3.6 Set `AUTOKUMA__ON_DELETE=delete` with a grace period
- [ ] 3.7 Pin the AutoKuma image — and use `2.0.0`, **not** `v2.0.0`: the
      v-prefixed tag is single-arch and will not pull on arm64

### Validation

```bash
kubectl logs -n monitoring deploy/autokuma          # connected, monitors synced
kubectl rollout restart deployment/autokuma -n monitoring
# monitor count must be UNCHANGED afterwards — this is the /data regression test
```

A monitor appears in Uptime Kuma without anyone opening the UI, and a restart
does not duplicate it.

---

## Phase 4: Lifecycle

### Tasks

- [ ] 4.1 `uis deploy <service>` adds its probe to the Secret
- [ ] 4.2 `uis undeploy <service>` removes it — AutoKuma then deletes the monitor
- [ ] 4.3 `uis monitors check` — compare intended against the Secret **and**
      against what Kuma is running, so a wedged AutoKuma is visible. Reconcilers
      fail silently; that is the same absence-renders-as-green trap
- [ ] 4.4 Optional `.uis.extend/monitors.yaml` — **only for things UIS does not
      depend on**: a hypervisor, a NAS, the watchdog's own host, job heartbeats.
      Anything UIS *depends on* is declared as a shim Service instead and
      discovered like any other Service — see
      [PLAN-system-dependencies-shim-services](./PLAN-system-dependencies-shim-services.md).
      If you find yourself hand-writing a monitor for a dependency, the bug is a
      missing shim. **Empty or absent on a stock install.**

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
- [ ] UIS writes only a Secret — never Kuma's database or Socket.IO API
- [ ] `uis monitors check` detects a stalled AutoKuma, not just missing files
- [ ] Probe definitions contain secret *names*, never values
- [ ] A stock install needs no `.uis.extend/monitors.yaml`

---

## Implementation Notes

**Probe through the Service, not the container.** Where a dependency runs
outside the cluster behind a shim Service, probing `postgresql.default:5432`
tests the whole path — shim, network, external process — which is what Temporal
and Authentik actually depend on. Probing the database host directly would stay
green while that path was broken. It also means installations that externalise
state need no special handling: UIS sees an ordinary Service either way.

⚠️ **This describes the target state, not the reference installation today.**
Verified on `asgard` 2026-08-08: `default/postgresql` and `default/minio` are
ordinary in-cluster services with pod endpoints; the production PostgreSQL on
Proxmox has no shim, and the only shims that exist are the two Ollama hosts. An
earlier revision of this note asserted the shim already existed and reasoned
from it. Getting there is
[PLAN-system-dependencies-shim-services](./PLAN-system-dependencies-shim-services.md),
which this plan should be read alongside.

**Why not keep the direct-to-database reconciler.** The reference deployment has
a working one, and it was tempting to promote it. Reading Kuma's own `add`
handler settled it: creating a monitor also calls `updateMonitorNotification`
(the `monitor_notification` join table — without it a monitor pages nobody),
`startMonitor`, and `bean.validate()`. A raw insert had already missed two of
those. Pinning the version makes the *schema* knowable, as it should — but the
work is reimplementing the application, not reading its tables.

**Four AutoKuma behaviours, all silent, all found by prototyping (2026-08-08).**
Listed because each one presents as "working" and would cost an implementer the
same day it cost here.

1. *Sidecar does not work.* Pod containers start together, Kuma needs ~30s, and
   AutoKuma makes one connect attempt then goes quiet — `Error during connect`,
   `Timeout while waiting for Kuma`, then nothing. Its own Deployment turns
   CrashLoopBackOff into the retry mechanism.
2. *Secret and ConfigMap mounts are symlink trees.* Kubernetes presents
   `name.json -> ..data/name.json` with `..data` itself a symlink to a
   timestamped directory. AutoKuma's scanner does not follow them: it connects,
   runs its migrations, finds no files, logs nothing, and syncs nothing. Copy
   with `cp -L` into an `emptyDir` first.
3. *`/data/autokuma.db` must be persisted.* It is the id → monitor mapping. With
   an ephemeral filesystem every restart re-creates every monitor as a new one —
   one restart took 19 monitors to 38, every name duplicated, no error anywhere.
4. *AutoKuma does not generate push tokens.* A push monitor rendered without one
   is created with an empty token, has no callable URL, and can never go UP; it
   only accumulates DOWN beats. The renderer must emit `push_token`.

**Derive push tokens, do not randomise them.** A push token *is* the URL a job
calls. Random tokens mean every rebuild reissues every URL, and the old URL goes
quietly silent rather than failing loudly. Deriving them —
`HMAC-SHA256(salt, monitor name)` — makes the whole set reproducible from one
secret, so a wipe-and-rebuild leaves every job's existing URL working. Verified
on the reference installation: two complete purge-and-rebuild cycles produced
byte-identical monitors and tokens. The salt becomes a secret that must be
backed up; losing it silently orphans every heartbeat caller.

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
- `manifests/230-autokuma-deployment.yaml` (new) — Deployment + PVC, not a sidecar
- `ansible/playbooks/230-setup-uptime-kuma.yml` — create the Secret and deploy AutoKuma
- `PLAN-system-observability-003-service-dashboards.md` — extend to three artifacts
- the service-authoring guide — document the `probes` artifact
