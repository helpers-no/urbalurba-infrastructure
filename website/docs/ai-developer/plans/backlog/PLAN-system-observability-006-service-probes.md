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

`PLAN-003` gives a service its own `dashboard` and `alerts`. So after it,
`uis deploy postgresql` yields a Grafana dashboard with no manual steps — but
**no availability probe**. The signal answering *"why is it slow?"* is
automated; the signal answering *"is it up?"* stays manual.

Worse, the gap is invisible. A missing dashboard is obvious the moment someone
looks for it. A monitor that was never created is indistinguishable from one
that is passing: **absence renders as green**.

The reference deployment now has 19 monitors, hand-written into a file on the
watchdog host. That is 19 pieces of knowledge — *"a sealed vault answers 503"*,
*"LiteLLM returns 200 with a dead database"* — that every other UIS installation
would have to rediscover the hard way.

## The insight that makes this cheap

The two things a monitor needs are **both already known to UIS**:

| Needed | Where it already is |
|---|---|
| *How* to probe this service — path, keyword, which secret | knowledge about the service → **ships with the service** |
| *Where* this service is | the `Service` and `Ingress` UIS created → **discovered** |

Verified on the reference deployment, with nothing hand-written:

```
k8s Service      → litellm.ai.svc.cluster.local:4000
IngressRoute     → HostRegexp(`litellm\..+`)
tailnet Ingress  → litellm.taile269d.ts.net
```

⚠️ **The user must not be asked for endpoints.** An earlier draft of this design
had the operator maintain a `monitors.yaml` of hostnames. That defeats the point
of UIS: a user runs `uis deploy` and should not need to know how the thing is
wired. Endpoints are **derived**, never declared.

---

## Phase 1: The probe artifact

### Tasks

- [ ] 1.1 Define the `probes` artifact, alongside `dashboard` and `alerts` from
      PLAN-003 — one observability contract per service, not two
- [ ] 1.2 Fields: `type`, `path` (relative — never a hostname), `keyword`,
      `accepted_statuscodes`, `ignore_tls`, `interval`, `maxretries`, and
      `auth: <secret_key_name>` which names a key in `urbalurba-secrets` and
      never a value
- [ ] 1.3 Write `probes/litellm.yaml` — the worked example for keyword matching
- [ ] 1.4 Write `probes/postgresql.yaml` — the worked example for a TCP probe
      **through the Service**, which is what makes the external-state topology
      work (see Implementation Notes)

### Validation

Both files parse; neither contains a hostname or a secret value.

---

## Phase 2: Discovery

### Tasks

- [ ] 2.1 Enumerate deployed services from the service registry
- [ ] 2.2 For each, resolve reachability: the `Service` for in-cluster, the
      `Ingress`/`IngressRoute` for the external hostname the watchdog needs
- [ ] 2.3 Resolve `auth:` by reading the named key from `urbalurba-secrets`
- [ ] 2.4 Render the joined result to a reviewable file before applying anything

### Validation

```bash
uis monitors render     # shows exactly what would be monitored
```

Rendered output for a service the user never configured matches what a human
would have written by hand.

---

## Phase 3: Reconcile

### Tasks

- [ ] 3.1 `uis monitors check` — report missing / extra / drifted, read-only
- [ ] 3.2 `uis monitors apply` — make the watchdog match
- [ ] 3.3 Never update or delete silently. Report drift; a human may have
      changed a monitor deliberately
- [ ] 3.4 Guard the target's schema/API before writing, and fail loudly if it
      has changed
- [ ] 3.5 Wire into `uis undeploy` so removing a service removes its monitor —
      the mirror half of the drift problem

### Validation

```bash
uis deploy redis && uis monitors apply && uis monitors check   # OK
uis undeploy redis && uis monitors check                       # no orphan
```

---

## Phase 4: Things UIS did not deploy

### Tasks

- [ ] 4.1 Optional `.uis.extend/monitors.yaml` for foreign targets only —
      a hypervisor UI, a NAS, machines outside the cluster, job heartbeats
- [ ] 4.2 Document that this file is **empty or absent on a stock install**

### Validation

A stock install monitors everything it deployed with no such file present.

---

## Acceptance Criteria

- [ ] `uis deploy <service>` on a cluster with the watchdog yields a monitor,
      with **zero user configuration**
- [ ] No endpoint or hostname is ever written by the user
- [ ] `uis undeploy <service>` removes the monitor
- [ ] `uis monitors check` reports drift rather than hiding it
- [ ] Probe definitions contain no secret values, only secret key names
- [ ] A stock install needs no `.uis.extend/monitors.yaml`

---

## Implementation Notes

**Probe through the Service, not the container.** On the reference deployment
PostgreSQL runs *outside* the cluster, reached through a shim Service. Probing
`postgresql.default:5432` tests the whole path — shim, backplane, external
container — which is what Temporal and Authentik actually depend on. Probing the
container's own address directly would stay green while production failed. This
also means installations that externalise state get monitored correctly with no
special handling: UIS sees an ordinary Service.

**Reference implementation exists.** The watchdog host in the reference
deployment already runs a reconciler with the schema guard, insert-only writes
and drift reporting described in Phase 3. Roughly 90% of Phase 3 is porting it;
what changes is the front end — assembling from discovery instead of reading one
flat list.

⚠️ **Transport is the open question, and it is deliberately not settled here.**
Uptime Kuma has no official API; the reference implementation writes to its
SQLite database, a private interface. That is acceptable for one operated
installation and a larger promise for a product. Phases 1 and 2 produce *data*
and are safe regardless — the rendered artifact in Phase 2.4 is also what
AutoKuma's (maintained) file source consumes, and what a config-as-code watchdog
such as Gatus would take directly. Choosing the transport later must not require
touching a single probe definition. See
[INVESTIGATE-system-monitor-definitions-with-services](./INVESTIGATE-system-monitor-definitions-with-services.md)
F3 and F4.

---

## Files to Modify

- `provision-host/uis/services/<category>/probes/<id>.yaml` (new, per service)
- `provision-host/uis/manage/uis-monitors.sh` (new)
- `provision-host/uis/manage/uis-cli.sh` — register the `monitors` verb
- `PLAN-system-observability-003-service-dashboards.md` — extend to three artifacts
- `website/docs/…` — document the `probes` artifact in the service-authoring guide
