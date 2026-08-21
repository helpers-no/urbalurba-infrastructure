# Declare external dependencies as shim Services

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: Every dependency UIS has on something outside the cluster is declared
as a `Service` with explicit `Endpoints`, so that discovery, monitoring and
documentation all read it from one place instead of each rediscovering it.

**Last Updated**: 2026-08-08

**Investigations**:
- [INVESTIGATE-system-monitor-definitions-with-services](./INVESTIGATE-system-monitor-definitions-with-services.md) — asked how monitors stay in step with services
- [INVESTIGATE-system-migrate-hosts-to-platforms](./INVESTIGATE-system-migrate-hosts-to-platforms.md) — installations differ in what is inside the cluster

**Related**: [PLAN-system-observability-006-service-probes](./PLAN-system-observability-006-service-probes.md)
consumes what this produces, and contains a factual error this plan corrects
(see Implementation Notes).

**Note**: [INVESTIGATE-system-roaming-dependency-addresses](./INVESTIGATE-system-roaming-dependency-addresses.md)
briefly challenged the "Endpoints are not reconciled" note below. **Challenge
withdrawn 2026-08-21** — this plan is unaffected and needs no amendment.

**Priority**: Medium

---

## Problem

UIS depends on things that do not run in the cluster. On the reference
installation that is OpenBao, a registry pull-through cache, the production
PostgreSQL, and two Ollama hosts.

Some of these are declared. Most are not:

```
ai/m1-ollama     → 192.168.68.70:11434     declared: Service + Endpoints
ai/mac-ollama    → 192.168.68.58:11434     declared: Service + Endpoints
OpenBao          → 192.168.68.77:8200      an IP in External Secrets' config
registry cache   → 192.168.68.78:5000      an IP in containerd's config
```

An undeclared dependency is invisible to everything that would otherwise
benefit from knowing about it. Nothing can enumerate it, nothing can probe it,
and nothing can tell you what breaks when it goes away.

This surfaced through monitoring, but monitoring is not the problem. Writing
availability probes forced the question *"what does this installation actually
depend on?"* and the answer turned out not to exist in any one place.

### Why this is not a monitoring concern

The naive fix is a hand-maintained list of external endpoints for the watchdog.
That was drafted and rejected: it asks the operator for addresses UIS already
has, and it drifts the moment anything moves.

The observation that makes it cheap instead:

> **If something in the cluster must reach it, it can be a Service. If it is a
> Service, everything that consumes Services gets it for free.**

A `Service` with manually-managed `Endpoints` is the standard Kubernetes way to
name something outside the cluster. Consumers connect to a stable DNS name
rather than an IP; when the address changes, one object changes.

Monitoring is then a *consequence*, not a mechanism. A probe attached to
`ai/m1-ollama` needs no hostname from the user — identical to an in-cluster
service. The probe renderer cannot tell the difference, and should not be able
to.

### The rule this produces

> **If you are hand-writing a monitor for something UIS depends on, the bug is
> a missing shim — not a missing monitor.**

Applied to the reference installation's 19 monitors:

| | Count | |
|---|---|---|
| In-cluster services | 4 | automatic today — litellm, grafana, temporal, authentik |
| Shim exists | 2 | automatic today — m1-ollama, mac-ollama |
| **Needs a shim** | **4** | **bao, registry-cache, external postgresql, external minio** |
| Derivable, not hand-written | 1 | k3s API — the watchdog's kubeconfig already holds the URL |
| Genuinely installation-specific | 3 | hypervisor, NAS, the watchdog's own host |
| Job heartbeats | 5 | not services; nothing can discover a job |

Ten of fourteen service monitors become automatic. The three that remain are
things UIS did not deploy and cannot be expected to know about, which is the
honest boundary.

---

## Phase 1: The dependency artifact

A service declares what it needs from outside the cluster, in the same place it
declares everything else about itself.

### Tasks

- [ ] 1.1 Define a `dependencies` artifact alongside the service definition —
      fields: `name`, `port`, `protocol`, and a human-readable `why`
- [ ] 1.2 Address resolution comes from `urbalurba-secrets` or the installation
      config, **never from the artifact** — the artifact is installation-agnostic
      and ships with the product
- [ ] 1.3 Render to a `Service` (no selector) plus an `Endpoints` object
- [ ] 1.4 Absent address ⇒ dependency not present in this installation ⇒ no
      Service rendered, and no error. An installation running everything
      in-cluster declares nothing and notices nothing

### Validation

```bash
uis dependencies list      # what this installation reaches outside the cluster
```

Output on a stock all-in-cluster install: empty.

---

## Phase 2: Probes attach to Services uniformly

### Tasks

- [ ] 2.1 The probe renderer from PLAN-006 resolves targets through the Service
      only — it must have no branch for "external"
- [ ] 2.2 Verify a shim-backed probe and an in-cluster probe render identically
      apart from the resolved endpoint

### Validation

Rendered output for `m1-ollama` (shim) and `litellm` (in-cluster) differ only in
name, port and path.

---

## Phase 3: Shim the reference installation's dependencies

Ordered by bootstrap risk, lowest first.

### Tasks

- [ ] 3.1 `registry-cache` — nothing in the cluster resolves it through DNS
      today (containerd reads a static config), so the shim is additive and
      safe to land first
- [ ] 3.2 `postgresql` — the external production instance. Consumers are
      Temporal, Authentik and LiteLLM. **Ordering matters**: the shim must exist
      before any consumer is pointed at it
- [ ] 3.3 `minio` — same shape, fewer consumers
- [ ] 3.4 `bao` — **last, and see Implementation Notes**. External Secrets needs
      the vault before most of the cluster exists, so this shim must not depend
      on anything the vault provides

### Validation

```bash
kubectl get endpoints -A          # every declared dependency resolves
uis dependencies list             # matches
```

Each consumer still works after being pointed at the Service name.

---

## Phase 4: Narrow what is left to the user

### Tasks

- [ ] 4.1 Rewrite PLAN-006 Phase 4.4. It currently describes
      `.uis.extend/monitors.yaml` as the place for anything external. Invert it:
      **the extend file is for things UIS does not depend on.** Anything it
      depends on gets a shim
- [ ] 4.2 Derive the cluster API monitor from the watchdog's kubeconfig rather
      than having anyone type it
- [ ] 4.3 Document the rule in the service-authoring guide, with the test from
      the Problem section stated as a rule

### Validation

A stock install has an empty or absent `.uis.extend/monitors.yaml`. The
reference installation's shrinks from six entries to three, and each remaining
entry is something UIS demonstrably did not deploy.

---

## Acceptance Criteria

- [ ] Every external dependency is a `Service` with `Endpoints`
- [ ] The probe renderer contains no special case for external targets
- [ ] Address values come from secrets or installation config, never from a
      product-shipped artifact
- [ ] An all-in-cluster installation declares no dependencies and sees no
      change in behaviour
- [ ] `.uis.extend/monitors.yaml` contains only things UIS did not deploy
- [ ] Consumers reach dependencies by DNS name; an address change touches one
      object

---

## Implementation Notes

**Correction to PLAN-006.** Its Implementation Notes state that on the
reference deployment PostgreSQL runs outside the cluster behind a shim Service,
and reason from that. Verified on `asgard` 2026-08-08: `default/postgresql` and
`default/minio` are ordinary in-cluster services with pod endpoints
(`10.42.0.203`, `10.42.0.204`). The production PostgreSQL on Proxmox has no
shim at all. The architectural argument in that note is sound and this plan
adopts it — but it describes a target state, not the current one, and should be
reworded to say so.

**Bao is bootstrap-sensitive.** External Secrets consumes the vault before most
of the cluster exists. A shim that depends on anything the vault provides is
circular. Keep it plain — Service and Endpoints, static address from
installation config, no secret reference. This is also why it is sequenced
last: it is the one where being wrong is expensive.

**A shim proves the path, not the health of the far end.** This is a feature for
Temporal, whose real dependency is the whole path — shim, network, external
process. It is a limitation for a probe: `bao` answers `503` when sealed, and a
sealed vault is useless even though the path is fine. The probe's
`accepted_statuscodes` still has to encode that. Declaring the dependency does
not remove the need to know what "healthy" means for it.

**Endpoints are not reconciled.** A manually-managed `Endpoints` object is
static. If an external host's address changes, the shim points at nothing and
the failure is a connection timeout at the consumer. This is a real downgrade
from a raw IP in config only in that it adds one indirection — but it is the
indirection that makes the address knowable and monitorable, and the probe on
the shim is exactly what detects it. Do not add address auto-discovery; it
would reintroduce the coupling this removes.

*Parked, not a request (2026-08-21).* A **declared ordered candidate list** is
arguably a different thing from discovery — the operator still writes down every
address here, and one that is not declared is never used. That distinction was
raised by
[INVESTIGATE-system-roaming-dependency-addresses](./INVESTIGATE-system-roaming-dependency-addresses.md)
and then withdrawn: the reconciler motivating it was ruled installation-specific,
so nothing in UIS currently needs it. Recorded so the argument does not have to
be rediscovered, not as an open item. The note above stands as written.

**Why not `ExternalName`.** `ExternalName` returns a CNAME and requires the
target to have a resolvable DNS name. The reference installation's dependencies
are bare IPs on a LAN. Service-plus-Endpoints also gives real port mapping,
which `ExternalName` does not.

---

## Files to Modify

- `provision-host/uis/services/<category>/dependencies/<id>.yaml` (new, per service)
- `provision-host/uis/manage/uis-dependencies.sh` (new)
- `provision-host/uis/manage/uis-cli.sh` — register the `dependencies` verb
- `manifests/` — shim Service + Endpoints per Phase 3
- `PLAN-system-observability-006-service-probes.md` — Phase 4.4 and the
  PostgreSQL note
- the service-authoring guide — document the `dependencies` artifact and the rule
