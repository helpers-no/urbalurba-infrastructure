# Investigate: Backup and scheduling — UIS deploys stateful services it cannot back up

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: Give UIS (a) a backup capability for the stateful services it deploys,
and (b) the scheduling primitive that backup — and everything else periodic —
depends on. Today UIS has neither. A reference implementation (pgBackRest with
verified point-in-time recovery) was built on a production deployment; its
findings and the scheduling trade-offs are recorded here.

**Related**: [INVESTIGATE-system-observability](./INVESTIGATE-system-observability.md),
[INVESTIGATE-system-registry-cache](./INVESTIGATE-system-registry-cache.md)
**Created**: 2026-08-05 — built and verified on Proxmox host `odin` / k3s `asgard`

---

## Background

UIS deploys **postgresql, mysql, mongodb, redis, elasticsearch, minio** — six
services that hold state. Searching the repo:

```bash
grep -rliE 'pg_dump|pgbackrest|wal_level|archive_mode' .   # → nothing
grep -rlE 'kind: CronJob|schedule:' manifests/ ansible/    # → nothing
```

**There is no backup capability and no scheduling primitive anywhere in UIS.**

This is arguably the most consequential gap in the platform. A developer can
`uis deploy postgresql`, put real data in it, and have no supported way to back
it up — and nothing warns them. `PLANS.md` even uses
`PLAN-service-postgresql-backup-cronjob.md` as its example filename, so the need
was recognised; it was never written.

---

## Part 1: Scheduling — decide this first, backup depends on it

Three schedulers are plausible in a UIS deployment. They are **not
interchangeable**, and the difference matters most for backups.

| Option | Strengths | Fatal for backups because… |
|---|---|---|
| **Kubernetes `CronJob`** | native, declarative, ships with the manifest | doesn't run when the cluster is down — exactly when you need a backup to have existed |
| **Temporal** (already in the catalogue) | durable, retries, history, visibility | **Temporal stores its own state in PostgreSQL** — scheduling Postgres backups in it is circular |
| **systemd timers on the host/CT** | independent of cluster *and* database; survives both | invisible to UIS: no `uis` command shows them, no central status, easy to forget |

### ⚠️ This is not the only scheduling question in the backlog

Three distinct layers, easily conflated:

| Layer | Examples | Owner |
|---|---|---|
| **Infrastructure jobs** | database backup, guest backup, offsite copy, cache warming | **this document** |
| **Data pipelines** | ingest → transform → catalogue, with DAGs, freshness and lineage | [INVESTIGATE-service-dagster](./INVESTIGATE-service-dagster.md) |
| **Durable workflows** | long-running business logic, retries, distributed workers | **Temporal** — already in the catalogue and deployed |

They are complementary, but note: the Dagster investigation (2026-04-21)
**predates Temporal being deployed** and does not consider it. Both are
orchestrators with durable state in PostgreSQL, both retry, both ship a UI —
running both is defensible (Dagster is asset/data-oriented, Temporal is durable
execution of arbitrary code) but should be a deliberate decision rather than an
accident, especially on a small node. **Worth resolving before implementing
either.**

Whatever is decided there, it does not change this document: neither Dagster nor
Temporal can own infrastructure jobs, for the reason below.

### The rule this produces

> **A backup job must not depend on the thing it backs up.**

Which implies a two-tier model, and UIS should say so explicitly:

- **Infrastructure jobs** — database backup, host/guest backup, offsite copy,
  cache warming. Must run when the cluster is down. Belong at the **host layer**.
- **Application jobs** — report generation, data pipelines, cleanup. Belong
  **in-cluster** (`CronJob`) or in **Temporal** when durability/retries/visibility
  matter.

### What is missing regardless of which is chosen

There is no way to **declare, discover or observe** a scheduled job:

```
uis jobs list           # what periodic work exists, where it runs, when it last ran
uis jobs status <job>   # last result, duration, next run
uis jobs run <job>      # run now (the thing you want when testing a backup)
```

Today an operator must know that `systemctl list-timers` on four different hosts
is the source of truth. That is exactly the kind of knowledge UIS exists to
remove.

**Ties into observability:** a scheduled job that silently stops is invisible
without alerting. "Last successful backup older than N hours" is the highest-value
alert a self-hosted platform can have — see
[INVESTIGATE-system-observability](./INVESTIGATE-system-observability.md) PLAN-004.

---

## Part 2: Backup — findings from the reference implementation

Built for the production PostgreSQL (which runs **outside** the cluster, per
[INVESTIGATE-system-remote-deployment-targets] topology).

### F1 — Logical dumps alone are a 24-hour data-loss window

`pg_dump` nightly is a good floor, but it means losing up to a day. Continuous
WAL archiving reduces the worst case to the archive interval. With
`archive_timeout=300` the measured RPO is **≤5 minutes** — a 288× improvement for
a few MB/day of compressed WAL.

Both are worth having: WAL/PITR for recency, logical dumps for selective restore
and for surviving repo corruption.

### F2 — pgBackRest is the right tool, and a "stanza" is just its config unit

`pgbackrest` 2.59 (in PGDG for bookworm) gives full/differential/incremental
backups, WAL archiving, PITR, retention, encryption and verification.

A **stanza** is one configuration unit: a PostgreSQL cluster plus where its
backups go. Cluster-level, not per-database — one stanza covered
`urbalurba_db`, `authentik` and `temporal` together. A second server would be a
second stanza. Worth defining in the docs; it is the one unfamiliar term.

### F3 — ⚠️ pgBackRest requires TLS for `s3` repos; MinIO-over-HTTP fails

Pointing the repo at the in-house MinIO produced:

```
ERROR: [101]: TLS error [1:167772427] wrong version number
```

`repo1-s3-verify-tls=n` disables *verification*, not TLS itself. Options are to
enable TLS on MinIO (which breaks existing plain-HTTP consumers) or use a
`posix` repo. **This will bite anyone who assumes "we have MinIO, use it as the
backup repo".** If UIS wants S3-repo backups pointing at its own MinIO, MinIO
needs TLS as a prerequisite — worth deciding deliberately.

### F4 — Repo encryption creates a new critical secret

`repo1-cipher-pass` encrypts the whole archive. **Lose it and every backup,
including offsite copies, is unreadable.** Any UIS backup feature must integrate
with the secrets layer rather than leaving the passphrase in a config file — see
[INVESTIGATE-system-observability]'s sibling secrets work.

### F5 — Restores must be tested, and the test finds real bugs

Restore-testing all four layers on this deployment found a **timezone bug**: the
database container ran `Etc/UTC` while the host ran `Europe/Oslo`, so the dump
job ran *three hours after* the off-box backup that was supposed to capture it.
Every offsite snapshot contained the **previous day's** dump — a ~48 h worst case
instead of 24 h. Nothing reported an error; both jobs "succeeded" every night.

Two lessons for any UIS backup feature:
1. **Cross-host schedule ordering is meaningless unless the hosts agree on a
   timezone.** Provisioning should set a consistent timezone, or schedules should
   be expressed in UTC.
2. Avoid scheduling in **02:00–03:00 local** — the European DST transition, where
   a timer can be skipped entirely at spring-forward or run twice in autumn.

### F6 — Restore gotcha worth documenting

On Debian, `postgresql.conf` lives in `/etc`, **not** in the data directory — so
a restored data directory won't start without one. A PITR test needs a minimal
`postgresql.conf` + `pg_hba.conf` supplied by hand. Similarly, restoring a
*privileged* LXC from `vzdump` requires `--unprivileged 0`, else `tar` fails with
a uid-mapping error.

---

## Part 3: Proposed plans (ordered)

```
PLAN-system-scheduling-001-jobs-primitive.md        ← decide + expose scheduled jobs
PLAN-service-postgresql-002-backup.md               ← pgBackRest, PITR, restore test
PLAN-system-backup-003-other-stateful-services.md   ← mysql/mongo/redis/elastic/minio
PLAN-system-backup-004-freshness-alerting.md        ← with the observability work
```

### PLAN-001 — Scheduling primitive

Adopt the two-tier model (Part 1), and add `uis jobs list|status|run`. Even if the
first implementation only *reports* systemd timers and k8s CronJobs it finds, the
discoverability alone is a large win.

*Acceptance:* `uis jobs list` shows every periodic job UIS created, where it runs,
when it last ran and whether it succeeded.

### PLAN-002 — PostgreSQL backup

Ship pgBackRest with the postgresql service: stanza creation, `archive_command`
wiring, retention, encryption via the secrets layer, and a documented restore +
PITR procedure. Must work for both in-cluster and external PostgreSQL.

*Acceptance:* a fresh `uis deploy postgresql` is backed up automatically; a
documented PITR restore recovers a row written minutes before the target time.

### PLAN-003 — The other stateful services

MySQL (`xtrabackup`/dumps), MongoDB (`mongodump`), Redis (RDB/AOF — decide whether
it counts as durable), Elasticsearch (snapshot API → S3), MinIO (`mc mirror` or
versioning + replication).

### PLAN-004 — Backup freshness alerting

Export last-success timestamps as metrics and alert when stale. Without this,
backups fail silently — as F5 demonstrates.

---

## Part 4: Open questions

1. **Where does the scheduler live** for a UIS install with no cluster yet, or a
   cluster that is down? Probably the host layer — the same "platform components
   beside the cluster" class as the external database, object store, secret store
   and registry cache. That class keeps recurring and may deserve first-class
   modelling.
2. **Should backups be on by default** for stateful services, or opt-in? Argument
   for default-on: the failure mode of forgetting is unrecoverable.
3. **Where do backups go by default?** Local disk is not a backup. MinIO is
   convenient but shares a failure domain and needs TLS (F3). Offsite needs
   credentials UIS doesn't currently manage.
4. **Retention defaults** — and who is responsible for not filling the disk.
5. **Does UIS want to own restore too?** `uis restore <service> --to <time>` is the
   command an operator actually wants at 3am, and it is where the value is.
