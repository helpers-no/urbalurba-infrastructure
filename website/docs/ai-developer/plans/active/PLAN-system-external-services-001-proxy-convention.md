# Plan: ship the external-service proxy that production already runs by hand

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Active — all phases done and verified on both topologies

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

- [x] 3.1 `uis list` shows `🔗 External → host:port` instead of `✅ Deployed`
- [x] 3.2 `040-test-postgresql.yml` asks the database `select version()` through
      `postgresql.<ns>`, exactly as consumers connect — the same test in both
      topologies. Registered in **all three** dispatch places; the audit now reads
      10 services, 0 broken

### Validation

The output tells the truth about where the data is. Reporting `✅ Deployed` for a
proxy to an unreachable host is the same defect class as Grafana reporting
`✅ Deployed` while absent from `list-enabled`.

---

## Phase 4: Prove both topologies

### Tasks

- [x] 4.1 **Rancher Desktop**: verified on the M1 with the shipped image
- [x] 4.2 **Reference installation**: migrated to the generated proxy
- [x] 4.3 Hand-written `pg-external-proxy.yaml` retired (moved to `/tmp` on the
      host rather than deleted, so a rollback needs no git archaeology)
- [x] 4.4 Rebuild-from-nothing test

### Validation

**4.1 — the same command, the same image, both topologies.**

Run on the M1 (`tecmacdev`) against Rancher Desktop k3s v1.36.2, using the
CI-built image — not a patched container:

| | asgard (external) | M1 Rancher Desktop (in-cluster) |
|---|---|---|
| object | `Deployment` + socat proxy | `StatefulSet/postgresql`, 16d |
| `uis list` | `🔗 External → 10.10.0.105:5432` | `✅ Deployed` |
| `uis verify postgresql` | `Topology: EXTERNAL - proxied to 10.10.0.105` | `Topology: in-cluster` |
| database answers | PASS — PG 18 on Odin CT 105 | PASS — **PostgreSQL 18.3** |
| recap | `failed=0` | `failed=0` |

With no declaration present the deploy path takes the in-cluster branch and
reports it as such; with one, it proxies and says where the data lives. **Both
halves of Principle 0 are now demonstrated on real hardware with shipped code.**

**4.2 — migration, with zero disruption.** `uis deploy postgresql` took the
external path and reported `changed=0`: Kubernetes itself confirming the rendered
template is identical to what production was already running. Before and after
are byte-identical —

```
deployment uid  3be1e368-...  unchanged
pod             postgresql-585c789479-w89hd  restarts=0  uid unchanged
clusterIP       10.43.219.89:5432  unchanged
```

The pod was never restarted. No consumer could have noticed the migration
happening, which is the strongest form of "consumers are unaffected".

**4.4 — rebuild from nothing.** The Deployment and Service were deleted outright,
confirmed gone (`NotFound`), and rebuilt from the four-line declaration:

```
uis deploy postgresql    changed=1   failed=0   14 seconds
```

Then verified end to end: `uis verify postgresql` → *"Database answers a real
query: PASS / Topology: EXTERNAL - proxied to 10.10.0.105"*, `uis list` →
`🔗 External → 10.10.0.105:5432`, and **0 pods in crashloop across the cluster**.

Before this plan, reconstructing that proxy meant someone remembering a
hand-written file existed. It is now 14 seconds from a declaration that says what
it is and why.

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

- [x] 5.1 Diffed. MinIO differs **structurally**, not just in values
- [x] 5.2 `045-minio-external-proxy.yml.j2` — renders **semantically identical** to
      the hand-written file (3 documents, 0 non-comment differences)
- [x] 5.3 Declared alongside postgresql in `external-services.yaml`
- [x] 5.4 Hand-written `minio-external-proxy.yaml` retired

### What MinIO actually proved

The plan said "if the template cannot express MinIO without a special case, the
template is wrong". **The postgres template cannot express MinIO** — and the
conclusion was the opposite of what that sentence assumed.

| | postgres | minio |
|---|---|---|
| forwarded ports | 1 (5432) | **2** — S3 API 9000 *and* console 9001 |
| socat containers | 1 | **2** |
| Services | 1 | **2** — `minio`, `minio-console` |
| selector label | `app.kubernetes.io/name` | `app` |
| exec client | `postgres:18` (psql) | `minio/mc` |

Forcing one generic template would mean parametrising labels, selectors, port
lists and client images — pushing each service's **shape** into
`external-services.yaml`, which is per-*installation* config. A service's shape is
shipped knowledge mirroring its real chart; only its address varies by
installation.

**So the design is one template per service, sharing a documented shape.** What
had to generalise was the shape, not the file — and MinIO proves it does, for a
service with twice the ports, twice the Services and different labels.

Doing this now rather than "later" is what surfaced it. One case looked like a
convention; two showed which half was accidental.

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
