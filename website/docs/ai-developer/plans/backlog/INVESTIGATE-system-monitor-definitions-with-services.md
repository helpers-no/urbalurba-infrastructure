# Investigate: should a service bring its own availability probe, and can Uptime Kuma accept one?

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: Decide how the external watchdog's monitors get created and stay in
sync as UIS gains services — before `002` hand-creates twenty of them.

**Last Updated**: 2026-08-07

**Related**:
- [INVESTIGATE-service-uptime-kuma](./INVESTIGATE-service-uptime-kuma.md) — decided
  *that* an external watchdog is needed (Option C). This does not reopen that.
- [INVESTIGATE-system-observability](./INVESTIGATE-system-observability.md) — Part 2
  and PLAN-003 establish the principle this extends.
- [PLAN-service-uptime-kuma-002-monitors](../active/PLAN-service-uptime-kuma-002-monitors.md) — the
  plan this would change.

---

## Questions to Answer

1. Observability PLAN-003 gives each service an optional `dashboard` and `alerts`
   artifact. Should it also give each service an **availability probe** artifact?
2. If yes, can Uptime Kuma consume one, and through what supported interface?
3. If it cannot, does that change which external watchdog UIS should standardise on?

---

## Current State

Two documents already state the principle, for the in-cluster stack:

> *"UIS already treats services as the unit of composition (`uis deploy <service>`).
> Observability should follow the same shape — a service brings its own scrape
> config, dashboard and alert rules."*
> — INVESTIGATE-system-observability, Part 2

> *"Give each service definition optional `dashboard` and `alerts` artifacts,
> applied when both that service and Grafana/Prometheus are deployed."*
> — PLAN-system-observability-003

The external watchdog does not follow that shape. `PLAN-service-uptime-kuma-002`
defines roughly twenty monitors, every one created by hand in a UI, on a
different machine, in a system with no link back to the service definition that
justifies it.

---

## Findings

### F1 — The asymmetry is structural, not an oversight

After PLAN-003, `uis deploy postgresql` yields a Postgres dashboard with no
manual steps. It yields **no availability probe**. The signal that answers
*"is it up?"* — the one the whole watchdog exists for — remains manual, while the
signal that answers *"why is it slow?"* is automatic.

Every future service widens the gap by one more hand-made monitor.

### F2 — The drift is silent and one-directional

A dashboard that is missing is obvious the moment someone looks for it. A monitor
that was never created looks identical to a monitor that is passing: **absence
renders as green**. This is the same failure shape as OBS-F1 (Alertmanager with
zero rules) and as the 82-day orphaned CNPG replica in
INVESTIGATE-service-uptime-kuma F1 — a component reporting health it never
actually measured.

`uis undeploy <service>` has the mirror problem: the monitor stays and alerts
forever on something deliberately removed.

### F3 — ⚠️ Uptime Kuma has no official API

There is no REST API in upstream `louislam/uptime-kuma`. Programmatic access is
via its **Socket.IO** interface, through community wrappers
(`uptime-kuma-api`, `uptime-kuma-api-v2`). Any UIS automation would depend on an
unofficial surface that upstream does not commit to.

### F4 — AutoKuma exists, but its Kubernetes provider is not production-grade

[AutoKuma](https://github.com/BigBoot/AutoKuma) is the established tool for
generating Uptime Kuma monitors automatically. It supports **Docker, Docker
Swarm, files, and Kubernetes**.

⚠️ Its **Kubernetes support is explicitly marked "as-is", has no active
maintainer, and is not recommended for production unless you are willing to
maintain it**. That is precisely the source UIS would need.

Its **file** source has no such caveat, and is the viable path: UIS renders
monitor definition files; AutoKuma reconciles them into Uptime Kuma.

### F5 — Config-as-code watchdogs exist and would compose natively

Uptime Kuma is UI-first by design; that is a fair trade for a homelab and a poor
one for a platform whose whole thesis is that services compose declaratively.
Alternatives such as **Gatus** define checks in YAML as their primary interface,
which maps directly onto a per-service artifact with no reconciliation daemon and
no unofficial API.

This does **not** reopen the Option C decision — an external watchdog is right.
It questions only *which* one, and the honest time to ask is before twenty
monitors are hand-built, not after.

### F6 — The heartbeat monitors are a separate case and are fine as they are

Investigation F4's push monitors (`enrichment-worker`, `pg-dump`, `vzdump`,
`restic-offsite`, `pgbackrest`) are configured **at the job**, not at the
service, and each needs a URL the job then calls. They do not suffer the drift in
F2 — a job that stops calling its URL is exactly the signal wanted. Any solution
here should leave Phase 4 of `002` alone.

---

## Options

### Option A: Accept manual monitors

**Pros:** zero work; `002` proceeds unchanged; correct if the service catalogue
is small and stable.
**Cons:** drift is permanent and silent (F2); the gap grows with every service;
contradicts the principle already committed to in observability Part 2.

### Option B: Per-service `probes` artifact → files → AutoKuma file source

Extend PLAN-003's pattern with a third optional artifact. UIS renders it to a
directory; AutoKuma's file source reconciles it into Uptime Kuma.

**Pros:** keeps Uptime Kuma; monitors ship with services; deletion propagates;
avoids the unmaintained k8s provider (F4).
**Cons:** a second moving part on the watchdog host; still ultimately writing
through an unofficial API (F3), just not by our own code.

### Option C: Re-evaluate the watchdog against config-as-code (Gatus et al.)

**Pros:** the artifact *is* the configuration — no daemon, no unofficial API, and
a per-service probe file is the native unit.
**Cons:** loses Uptime Kuma's status page, its 90+ notification integrations and
its first-class push monitors; `001` is already deployed and merged; a real
reversal cost.

---

## Recommendation

**Do not block `002`.** The manual monitor set is needed now and its content is
independent of how monitors are authored later.

**Do decide before the catalogue grows.** Suggested sequence:

1. Let `002` and `003` complete as written
2. Evaluate Option B against Option C on one service — `postgresql` — measuring
   effort to define, to change, and to delete
3. If Option B holds, add `probes` alongside `dashboard` and `alerts` in
   PLAN-system-observability-003 rather than as a separate mechanism, so a
   service has **one** observability contract, not two

⚠️ The cost of deciding late is not the rework — it is twenty hand-made monitors
that nobody trusts enough to delete.

---

## Open Questions for the Maintainer

- Is Uptime Kuma intended as **the** UIS watchdog for all installs, or as the
  reference deployment's choice? Option C is only worth weighing under the first.
- Should `uis undeploy` be required to remove observability artifacts? That is a
  broader lifecycle question than monitoring alone.
- Does the status page matter as a product feature? It is Uptime Kuma's clearest
  advantage over config-as-code alternatives and may settle this on its own.
- Where would rendered probe files live on a watchdog host that is deliberately
  **not** part of the cluster (INVESTIGATE-service-uptime-kuma F8, the
  "components beside the cluster" gap)?

---

## Next Steps

- [ ] Maintainer answers the Uptime-Kuma-as-standard question above
- [ ] Spike Option B on `postgresql` after `002` completes
- [ ] Fold the outcome into `PLAN-system-observability-003-service-dashboards.md`
