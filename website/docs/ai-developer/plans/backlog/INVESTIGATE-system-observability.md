# Investigate: Observability — the stack deploys, but the signals don't arrive

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: Make a UIS deployment actually observable. The observability stack
installs and reports healthy, but no telemetry reaches it — there are no alert
rules, no log collection, and nothing outside Kubernetes is monitored. This
investigation documents the gaps with reproducible evidence and proposes five
ordered plans.

**Related**: [INVESTIGATE-system-remote-deployment-targets](./INVESTIGATE-system-remote-deployment-targets.md),
[INVESTIGATE-cli-stack-profiles](./INVESTIGATE-cli-stack-profiles.md) — the
install-shape and testing companion to this document; it answers Q3 and Q4 below
and corrects Q4's original premise

**Finding IDs**: findings here are prefixed `OBS-` so cross-references between
the two documents are unambiguous (the companion uses `CLI-`).
**Created**: 2026-08-05 — findings measured on a production k3s cluster (see Appendix)

---

## Background

`uis stack install observability` deploys Prometheus, Loki, Tempo, the OTel
Collector and Grafana. On a real production cluster (k3s `asgard`, Proxmox host
`odin`) all five deploy and report healthy, and each service's own E2E test
passes.

**But the platform is not observable.** The components are installed; the
telemetry pipelines that would make them useful are not connected. This
investigation documents what is missing, with reproducible evidence, and
proposes an ordered set of plans.

The distinction matters because the current state is the dangerous kind: a
monitoring stack that *looks* deployed, consumes ~4 GB RAM and ~40 GB of
storage, and would not tell you if the platform broke.

---

## Part 1: Findings (measured, with repro)

### OBS-F1 — There are no alert rules. Monitoring cannot alert. (severity: high)

```bash
curl -s "$PROM/api/v1/rules"
{"status":"success","data":{"groups":[]}}
```

Alertmanager is deployed (`prometheus-alertmanager-0` Running) and has storage
provisioned, but **zero rules are loaded**. No condition on any service will ever
notify anyone. This is the single biggest gap: everything else in the stack is
for *investigating* a problem you already know about; alerts are how you find out.

### OBS-F2 — Nothing ships logs to Loki. It contains only its own test data. (severity: high)

```bash
curl -s "$LOKI/loki/api/v1/label/job/values"
{"status":"success","data":["loki-validation"]}
```

`loki-validation` is the log the deployment's own E2E test pushed. There is **no
log-shipping agent** in the cluster:

```bash
kubectl get pods -A | grep -iE 'promtail|alloy|fluent|vector'   # → nothing
```

So container logs are never collected. Loki, its gateway, its canary and a 10 GB
PVC are running to store test data. `kubectl logs` remains the only way to read
logs, which does not survive pod restarts and cannot be searched across services.

### OBS-F3 — Tempo receives no traces from anything real. (severity: medium)

Same shape as OBS-F2: Tempo is deployed and queryable, but only the E2E validation
trace has ever reached it. Nothing documents how an application should send
traces, and no UIS service is instrumented.

Relevant data point: an application team using this platform was shipping OTLP
traces/metrics/logs to **Grafana Cloud** because there was no documented local
path — a self-hosted stack was running the whole time.

### OBS-F4 — Only Kubernetes is monitored. (severity: high for production)

Prometheus scrape jobs, in full:

```
 1 x kubernetes-api-servers      1 x kubernetes-nodes
 1 x kubernetes-nodes-cadvisor   5 x kubernetes-pods
 8 x kubernetes-service-endpoints
 1 x prometheus                  1 x prometheus-pushgateway
```

Every target is inside the cluster. In a production UIS deployment, critical
components are deliberately **outside** it:

| Component | Why outside | Monitored? |
|---|---|---|
| PostgreSQL | survives cluster failure; bootstrap/recovery | ❌ |
| Object storage (MinIO/S3) | reachable by workers outside the cluster | ❌ |
| Secret store | must not depend on the cluster it serves | ❌ |
| Hypervisor / host | runs everything | ❌ |
| Storage pool (ZFS/LVM), disk health | where the data lives | ❌ |
| Backups (dumps, snapshots, offsite) | the last line of defence | ❌ |

A cluster-only view will happily report "all green" while the database host is
out of disk, the SSD is failing, or backups have silently not run for a week.
**For a production install, the components outside Kubernetes are the ones whose
failure is unrecoverable.**

### OBS-F5 — No service dashboards ship with services

Each service knows what "healthy" means for itself, but that knowledge isn't
expressed anywhere. An operator gets Grafana with generic Kubernetes views and
must build service views by hand.

### OBS-F6 — The Grafana E2E test fails deployment on a timing race

`034-setup-grafana.yml` pushes a trace then queries it back within 3 retries.
Tempo does not make traces searchable until it flushes a block, so the play
aborts with `GRAFANA DATASOURCE VALIDATION FAILED` **while the stack is healthy**
— and because it aborts, the `enable` step never runs, leaving Grafana running,
reported `✅ Deployed` by `uis list`, but **absent from `uis list-enabled`**.

(Also tracked as a standalone defect; repeated here because it shapes any work on
the observability playbooks.)

---

## Part 2: What "better observability" should mean for UIS

UIS's promise is a platform you use *without* knowing Kubernetes. Applied to
observability, that implies three properties the current stack doesn't have:

1. **Signals arrive by default.** Deploying the stack should collect logs and
   metrics from everything UIS deployed, with no further wiring. Today the
   operator must know to add an agent that isn't in the catalogue.
2. **The platform tells you when it is unhealthy**, without the operator writing
   PromQL first. A baseline rule set shipped with UIS is the difference between
   "monitoring installed" and "monitored".
3. **It covers the whole deployment, not just the cluster** — including the
   external database, object store, secret store and host that a production
   topology depends on.

A useful framing: UIS already treats *services* as the unit of composition
(`uis deploy <service>`). Observability should follow the same shape — a service
brings its own scrape config, dashboard and alert rules, so `uis deploy postgresql`
also makes Postgres observable.

---

## Part 3: Proposed plans (ordered)

```
PLAN-system-observability-001-log-collection.md     ← Loki is decorative without this
PLAN-system-observability-002-alert-baseline.md     ← makes it "monitored"
PLAN-system-observability-003-service-dashboards.md ← per-service, ships with the service
PLAN-system-observability-004-external-targets.md   ← the production-topology gap
PLAN-system-observability-005-app-telemetry.md      ← the dev→prod story for apps
```

### PLAN-001 — Log collection (highest value, unblocks OBS-F2)

Add a log-shipping agent to the observability stack so container logs reach Loki
automatically.

**Decided: Grafana Alloy.** This was an open question when first written; it no
longer is. **Promtail reached end-of-life on 2 March 2026** — support has ended
and all development moved to Alloy, so it is not a candidate. Alloy is a
vendor-neutral distribution of the OTel Collector and handles logs, metrics and
traces, so it also subsumes the standalone collector, taking the stack from 5
components to 4.

Two practical notes:

- This is **not** a Promtail migration — UIS has no Promtail to convert
  (that is OBS-F2). It is a greenfield install. The existing collector config
  *can* be converted: `alloy convert --source-format=otelcol`.
- Alloy's DaemonSet defaults (100m/128Mi requests, 500m/512Mi limits) match what
  the OTel Collector is already allocated, so log collection arrives at roughly
  no additional cost.
- Alloy emits different metrics than Promtail or the collector; any dashboard or
  alert built on collector metrics needs updating.

*Acceptance:* after `uis stack install observability`, `logcli`/Grafana can query
logs from every namespace; `job` label values include real services, not just
`loki-validation`.

### PLAN-002 — Baseline alert rules + routing

Ship a default rule group covering: node/pod not ready, pod crash-looping, PVC
above ~85%, node disk/memory pressure, target down, certificate expiry. Plus
Alertmanager routing so alerts have somewhere to go.

*Open question:* what receiver is the sensible default for a self-hosted install
(email needs SMTP; ntfy/Gotify are self-hostable; Slack/Discord need a webhook)?
Suggest: rules shipped enabled, receiver configured via `.uis.extend`, with a
loud warning while unconfigured.

*Acceptance:* stopping a deployment produces a firing alert visible in
Alertmanager and Grafana within ~2 minutes.

### PLAN-003 — Per-service dashboards and scrape config

Give each service definition optional `dashboard` and `alerts` artifacts, applied
when both that service and Grafana/Prometheus are deployed. Start with the
services most likely to break: postgresql, redis, minio, temporal, traefik.

*Acceptance:* `uis deploy postgresql` on a cluster with the observability stack
yields a Postgres dashboard in Grafana with no manual steps.

### PLAN-004 — Targets outside Kubernetes (OBS-F4)

Support scraping components UIS did not deploy into the cluster:
- an `.uis.extend` list of external scrape targets, rendered into Prometheus config
- guidance/manifests for the standard exporters (`postgres_exporter`,
  `node_exporter`, MinIO's built-in `/minio/v2/metrics`, `zfs`/SMART where relevant)
- **backup freshness as a first-class signal** — "last successful backup older
  than N hours" is arguably the single most valuable alert a self-hosted platform
  can have, and nothing currently produces it

*Acceptance:* on a deployment with an external database, Grafana shows database
and host health, and an alert fires when the last backup exceeds its threshold.

### PLAN-005 — Application telemetry (the dev→prod story)

Document and template how an application emits traces/metrics/logs to the
in-cluster OTel Collector, with the same endpoint working in local development
(Rancher Desktop) and production. This is the piece that keeps teams from
defaulting to a cloud APM vendor, and it aligns with the existing
`uis configure` pattern: the platform hands the app its connection details.

*Acceptance:* a scaffolded app emits a trace locally and in production with no
code change, only configuration.

---

## Part 4: Open questions for the maintainer

1. ~~**Alloy vs Promtail + OTel Collector.**~~ **Settled — Alloy.** Promtail
   reached end-of-life on 2 March 2026, so this is no longer a trade-off. See
   PLAN-001 above.
2. **Should observability be opt-in or part of a default production profile?**
   It costs ~4 GB RAM and ~40 GB storage measured here — significant on small
   nodes, cheap on a real server.
3. **How much should Grafana require?** Today it hard-depends on Prometheus *and*
   Loki *and* Tempo. Making Loki/Tempo optional would let small installs run
   metrics-only. (Tracked separately.)
4. **Retention and sizing defaults.** *(Corrected 2026-08-05 — the original
   wording, "no documented retention policy", was wrong.)* Retention **is**
   configured: Prometheus `15d`, Tempo `24h`, Loki `retention_period: 24h` with
   the compactor enabled. The actual defect is that the 8–10 GB claims were
   sized independently of those windows — 24h of logs or traces is orders of
   magnitude smaller than a 10 GB claim — and that **all retention is
   time-based, with no size cap** (`retentionSize` appears nowhere), so a disk
   can still fill before the window elapses. Analysed in
   [INVESTIGATE-cli-stack-profiles](./INVESTIGATE-cli-stack-profiles.md) CLI-F3.
5. **Does observability belong in the `system` area or its own?** This
   investigation assumes `system`; if observability grows service-level artifacts
   (PLAN-003), a dedicated area may be warranted.

---

## Appendix: environment the findings come from

Production k3s cluster `asgard` (v1.36.2) on Proxmox host `odin`; 13 UIS services
deployed including postgresql (external), minio (external), temporal, redis,
authentik, and the full observability stack. Prometheus scraping 18 targets,
Grafana healthy, Loki and Tempo queryable. Node usage after the full stack:
4.7 GiB / 10 GB RAM, ~23% of 4 vCPU.
