# Plan: ship the external-service proxy that production already runs by hand

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Active — Phases 1–2 done and verified; Phases 3–5 open

**Goal**: `uis deploy postgresql` gives an in-cluster PostgreSQL on a laptop and a
transparent proxy to the external one on a production installation — **same
command, same in-cluster address, consumers unchanged** — with the topology
declared in `.uis.extend/` rather than hand-built.

**Last Updated**: 2026-08-13

---

## Dependencies

**Investigation**: [INVESTIGATE-system-external-or-in-cluster-services](../backlog/INVESTIGATE-system-external-or-in-cluster-services.md) — EXT-F1, EXT-F2, EXT-F3.

**Prerequisites**: none.

**Blocks**: the OpenBao / registry-mirror / cluster-backup service plans. All three need
this convention, and three separate answers would never converge.

**Priority**: High

---

## Problem Summary

Principle 0 says every service must run on a developer's laptop, and production
may differ in topology but never in interface. PostgreSQL already lives that
shape — and the mechanism that makes it work is **hand-built, undocumented, and
would not survive a rebuild**.

### What production actually runs (measured 2026-08-13)

`.uis.extend/pg-external-proxy.yaml` on the reference installation deploys, into
`default`, under the name and labels of the real service:

| Piece | Why |
|---|---|
| `Deployment/postgresql`, label `app.kubernetes.io/name=postgresql` | so `SCRIPT_CHECK_COMMAND` and `uis list` work **unchanged** |
| first container `postgres:18`, `sleep infinity` | so playbooks that `kubectl exec` into "the postgres pod" for `psql` work **unchanged** |
| sidecar `alpine/socat` → `10.10.0.105:5432` | forwards to the real database on Odin |
| `Service/postgresql` | so `PGHOST=postgresql.default` resolves **identically** in both topologies |

That last row is the whole trick. Every consumer — openwebui, gravitee, temporal,
unity-catalog, openmetadata — reads `${PGHOST}`, and **none of them change**.
Interface identical, topology different, exactly as Principle 0 requires.

The socat target is deliberately the backplane address (`10.10.0.105`, CT 105 over
`vmbr1`) and **not** the tailnet one: asgard and the database sit on the same
Proxmox host, so this traffic must not depend on WireGuard or on Tailscale's
coordination server being reachable.

### Why this is a problem rather than a success

- It exists only as a file someone wrote by hand on one machine. Rebuild asgard
  and PostgreSQL connectivity is reconstructed from memory.
- `minio-external-proxy.yaml` is the same pattern applied a second time, also by
  hand — so it is a convention already, just an unowned one.
- Nothing in UIS knows the topology differs. `uis list` reports PostgreSQL exactly
  as if it were deployed in-cluster, which is true of the *pod* and false of the
  *database*.
- 14 files sit in that installation's `.uis.extend/`, including `bao-reviewer.yaml`
  and `eso-store.yaml`. This plan productises one pattern; the rest remain
  evidence of how much of the reference installation is hand-built.

**This plan does not design a convention. It ships the one that already works.**

---

## Phase 1: Template the proxy

### Tasks

- [x] 1.1 `ansible/playbooks/templates/040-postgresql-external-proxy.yml.j2`,
      parametrised by `_external_host`, `_external_port`, `namespace` — and by
      nothing else, so accidental variation cannot creep in
- [x] 1.2 All four properties kept, with the comments explaining why
- [x] 1.3 Rendered against the reference installation's values and diffed against
      the hand-written file
- [x] 1.4 *(added)* `templates/README.md` gained a **third case**. It documented
      static manifests and multi-instance templates only; this is single-instance
      but parametrised per installation, and fitted neither

### Validation

**Passed.** Rendered with `_external_host=10.10.0.105`, `_external_port=5432`:

| Check | Result |
|---|---|
| YAML documents | 2 vs 2 |
| Parsed objects vs production's file | **identical** — every key, value and structure |
| Non-comment textual differences | **0** |
| Comment differences | 10 lines, deliberate — see below |
| Alternate values (`192.0.2.10:6543`, ns `data`) | render cleanly |

The only textual differences are comments, changed on purpose: the hand-written
file says *"the real external database on Odin … asgard and pg sit on the same
Proxmox host"*, which is false for any other installation rendering this template.
The guidance is kept but generalised — prefer a backplane address over a tailnet
one when the database and cluster share a host — with Odin named as the example
rather than the rule.

---

## Phase 2: Declare the topology

### Tasks

- [x] 2.1 `.uis.extend/external-services.yaml` — installed by `first-run.sh` as a
      fully-commented file that **declares nothing**, so the capability is
      discoverable by reading your own extend dir rather than only the docs
- [x] 2.2 `why:` required — deploy refuses without it, and says why it refused
- [x] 2.3 `uis deploy <id>` consults it: absent ⇒ in-cluster exactly as today;
      present ⇒ `900-external-service-proxy.yml` renders the proxy instead
- [x] 2.4 Absent is silent — verified below

Implemented as `provision-host/uis/lib/external-services.sh` (three functions:
`is_external_service`, `external_service_get`, `external_service_template`) plus a
short branch in `service-deployment.sh`. The generic playbook resolves the
per-service template by the `<NNN>-<id>-external-proxy.yml.j2` convention and
**fails with an explicit message** when a declared service has no template, rather
than deploying nothing and reporting success.

### Validation

**Passed.** 9/9 unit tests against the helper, run in the provision-host container:

| Case | Result |
|---|---|
| no file at all — the stock laptop case | not external |
| commented file `first-run` installs | not external |
| a *different* service declared | not external |
| declared service | external |
| entry missing `why:` | **refused**, and says why |
| valid entry | `host port why` returned |
| port omitted | falls back to the service default |
| template name from playbook prefix | `040-postgresql-external-proxy.yml.j2` |

And on the reference installation, with no declaration file present: `uis list`
runs clean, PostgreSQL and MinIO report exactly as before. Nothing changed for an
installation that has not opted in.

Note `uis list` still reports PostgreSQL as `✅ Deployed` there — true of the pod,
misleading about the data. That is Phase 3's job.

---

## Phase 3: Say which topology is running

### Tasks

- [ ] 3.1 `uis list` / `uis status` distinguish in-cluster from external, showing
      the target address
- [ ] 3.2 `uis verify postgresql` proves the *database* answers, not that a pod is
      Running — the proxy makes those two different claims, and only one matters

### Validation

The output tells the truth about where the data is. Reporting `✅ Deployed` for a
proxy to an unreachable host is the same defect class as Grafana reporting
`✅ Deployed` while absent from `list-enabled`.

---

## Phase 4: Prove both topologies

### Tasks

- [ ] 4.1 **Rancher Desktop**: `uis deploy postgresql` → in-cluster database,
      consumers work
- [ ] 4.2 **Reference installation**: replace the hand-written file with the
      generated one, redeploy, confirm consumers are unaffected
- [ ] 4.3 Delete `.uis.extend/pg-external-proxy.yaml` once the generated form has
      replaced it — two sources for one object is how they drift apart
- [ ] 4.4 Rebuild-from-nothing test on the reference installation: the proxy comes
      back from the declaration alone

### Validation

The same command, run on a laptop and on production, produces a working
PostgreSQL for consumers in both — and neither required a hand-written file.

---

## Phase 5: Prove it generalises — MinIO

One service proves the template works. Two prove it is a **convention** rather
than a PostgreSQL-shaped accident, and MinIO is available immediately: it already
has both halves — `service-minio.sh` and a hand-written
`minio-external-proxy.yaml` following the same pattern against CT 107.

Doing it here rather than "later" is deliberate. A convention validated on exactly
one case is indistinguishable from a special case, and the differences MinIO
brings are the useful part.

### Tasks

- [ ] 5.1 Diff `minio-external-proxy.yaml` against `pg-external-proxy.yaml` and
      record what genuinely differs — ports, health path, whether a client-image
      first container is needed at all. Those differences are what the template
      must parametrise; anything else is accidental variation to remove
- [ ] 5.2 Render MinIO from the same template with only declared values changed.
      **If the template cannot express it without a special case, the template is
      wrong** — fix it before adding a third consumer
- [ ] 5.3 Declare it in `external-services.yaml` alongside postgresql
- [ ] 5.4 Delete the hand-written `minio-external-proxy.yaml`

### Validation

Two services, one template, one declaration file, zero hand-written proxies on the
reference installation. MinIO consumers unaffected.

---

## Out of Scope

- OpenBao, registry mirrors, cluster backup — they consume this convention, they
  do not define it.
- The **host-layer backup stack** (vzdump / sanoid / syncoid / restic /
  pgBackRest). It is not a service and cannot run on a laptop — see EXT-F6.
- The other 11 files in the reference installation's `.uis.extend/`.

---

## Note on a wrong turn

This plan was nearly written as "design a mechanism for declaring external
services". Looking at what the reference installation actually runs showed the
mechanism already exists and is better than what would have been designed —
particularly the choice to keep the real service's name, labels and first
container, so that *nothing downstream knows the difference*.

The earlier claim that "asgard runs PostgreSQL in-cluster" was also wrong. That
pod is the proxy; `2/2 Running` is `postgres:18` plus `socat`, not a database.
