# Investigate: services that run outside the cluster in production, and inside it on a laptop

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Created**: 2026-08-13

## Status: Backlog

**Goal**: Decide how a service can be *provided externally* in one installation
and *deployed in-cluster* in another, behind one identical `uis` interface — so
the components currently hand-built on Odin become reproducible, and a developer
on Rancher Desktop gets working equivalents.

---

## Background

UIS's promise is that a developer on Rancher Desktop and a production install are
the same platform: **identical interface, topology may differ.**

Three components on the reference installation break that promise. They are
absent from `/services` because they have no service definition, and they are
absent from the platform because they were built by hand:

| Component | Runs as | Service definition | Investigation | Documented |
|---|---|---|---|---|
| **OpenBao** | LXC on Odin (CT 108) | none | **none** | `production/secrets.md` |
| **Registry cache** | own host | none | [system-registry-cache](INVESTIGATE-system-registry-cache.md) | `production/registry-cache.md` |
| **Backup** (restic / pgBackRest) | hypervisor layer | none | [system-backup-and-scheduling](INVESTIGATE-system-backup-and-scheduling.md) | `production/proxmox.md` |

This is the state Alloy was in before it was made a real service. That commit
said it plainly: *"I had helm-installed Alloy by hand. It had no service
definition, no playbook, and was not referenced by uis at all — on a rebuild it
simply would not have existed."* Rebuild Odin tomorrow and OpenBao, the registry
cache and the backup chain are rebuilt by hand, from memory. OpenBao holds the
vault recovery keys.

**They are not on the services page because they are not services. That page is
correct. The gap is that they are not reproducible.**

---

## Part 1: Findings

### EXT-F1 — There is no way for a service to be "provided externally"

`uis deploy <service>` installs into the cluster. There is no way to say *this
installation already has one, at this address, do not deploy it* — so an operator
either deploys a duplicate or edits nothing and the service is simply absent.

Consumers have the same gap: nothing tells an app whether to use the in-cluster
address or an external one.

### EXT-F2 — The precedent already exists, twice, but only for monitoring

`.uis.extend/` is the established home for *things UIS did not deploy*, and it
has shipped twice:

- `PLAN-system-observability-004` — external scrape targets
- `PLAN-service-uptime-kuma-005` — `.uis.extend/monitors.yaml`, with the rule
  **"never ask the user for an endpoint UIS already knows"**

Both solve *watching* something external. Neither solves *substituting* for it.
The convention is half-built and should be finished rather than duplicated.

### EXT-F3 — Six database services already live this shape, undeclared

`postgresql`, `mysql`, `mongodb`, `redis`, `elasticsearch`, `qdrant` all ship as
in-cluster services while a production topology may run them outside. The
reference installation does exactly this with PostgreSQL 18 on a separate host.
That arrangement works today only because nobody wrote it down — it is convention
by omission, and this investigation should capture it rather than invent a
parallel mechanism for three new components.

### EXT-F4 — "Runs on a laptop" is not equally meaningful for all three

- **OpenBao** — an in-cluster instance is a genuine equivalent. Dev secrets are
  not production secrets, and that is fine.
- **Registry cache** — a genuine equivalent, and arguably more valuable on a
  laptop than in production, since a developer rebuilds clusters constantly.
- **Backup** — **not equivalent, and the investigation must say so.** A backup
  service running inside the cluster it backs up is not a backup. On Rancher
  Desktop it can only be a functional stand-in that proves the interface and the
  restore path, never the guarantee. Claiming parity here would be a lie the
  platform tells its users.

---

## Part 2: What the answer has to satisfy

1. **One interface.** The same command works on both topologies. If a developer
   learns `uis deploy openbao` and an operator does something unrecognisable, the
   parity claim is false.
2. **Declaring "external" is per-installation, not per-service.** The service
   definition is shipped code; where *this* installation's OpenBao lives is local
   configuration. That is what `.uis.extend/` is for.
3. **Consumers must not care.** Whatever an app reads to find OpenBao must be the
   same key in both topologies, resolving to different addresses.
4. **Absent is normal.** A stock install declares nothing and everything runs
   in-cluster. The extend file stays empty until someone has an external
   component — matching the rule kuma-005 already holds.
5. **Never ask for an endpoint UIS already knows.** Inherited from kuma-005, and
   it is the difference between configuration and busywork.

---

## Part 3: Open questions

- **Q1.** Does "external" belong in `.uis.extend/` as a new file (e.g.
  `external-services.yaml`), or as a field on the existing
  `enabled-services.conf`? The former keeps concerns separate; the latter keeps
  the answer next to the list of what to deploy.
- **Q2.** How does a consumer get the address? A generated secret/ConfigMap key
  with a fixed name is the obvious route, since `urbalurba-secrets` already works
  that way — but it needs deciding, not assuming.
- **Q3.** Should `uis list` show externally-provided services, and how? Reporting
  them as "not deployed" is misleading; omitting them hides real infrastructure.
  This is the same class of bug as Grafana reporting `✅ Deployed` while absent
  from `list-enabled`.
- **Q4.** Does health checking apply? `SCRIPT_CHECK_COMMAND` assumes `kubectl`.
  An external component needs a different probe, or none.
- **Q5.** For backup specifically — what *is* the laptop deliverable? Proving the
  restore path against a local MinIO is defensible; pretending to be a backup is
  not.

---

## Part 4: Relationship to other open work

**This shares its shape with the observability artifact-convention decision**
(`PLAN-system-observability-003` task 1.4 and `PLAN-system-observability-006`
task 1.1). Both are asking: *how does a service declare something about itself
that the platform then acts on, per installation?* Deciding them together avoids
two conventions that never converge — which is exactly what 003 and 006 already
warn about between themselves.

**Do not start the three service builds before that decision.** Three services
each inventing their own way of being "external in production" is the drift this
investigation exists to prevent.

---

## Part 5: Proposed plans (ordered, to be drafted after the questions above are answered)

1. **The convention** — declaring an externally-provided service, and how
   consumers resolve its address. No new services; just the mechanism, proven by
   retrofitting PostgreSQL, which already lives this way undeclared (EXT-F3).
2. **OpenBao as a UIS service** — in-cluster for dev, external on Odin. Highest
   value: it is the only one of the three with no investigation of its own today,
   and it holds the recovery keys.
3. **Registry cache as a UIS service** — folds in
   [system-registry-cache](INVESTIGATE-system-registry-cache.md).
4. **Backup** — folds in
   [system-backup-and-scheduling](INVESTIGATE-system-backup-and-scheduling.md),
   and must state in its own goal what a laptop deliverable is and is not
   (EXT-F4).
