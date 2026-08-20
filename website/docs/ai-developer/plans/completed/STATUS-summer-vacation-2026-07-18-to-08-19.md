# Summer vacation work summary: 18 July – 19 August 2026

## Status: Reference — a retrospective, not a plan

**Scope**: everything merged to `main` between 2026-07-18 and 2026-08-19.
**Volume**: 145 commits, 58 pull requests, 4 new services, 30 plans and
investigations written.

This is a record of what happened and why, kept because several of the decisions
below are load-bearing and the reasoning is worth more than the diff.

---

## 1. Four services packaged

| Service | Date | Notes |
|---|---|---|
| **MinIO** | 28 Jul | Object storage; reclassified to `STORAGE` |
| **Temporal** | 28 Jul | Workflow engine |
| **Uptime Kuma** | 7 Aug | The external watchdog, on `assist` |
| **Alloy** | 11 Aug | Log collection into Loki |

Uptime Kuma took the longest path: investigated → deployed → packaged as a
first-class service → first-run wizard removed → `uis undeploy --purge` honoured
→ history retention seeded → AutoKuma folded in as part of the service.
See [PLAN-service-uptime-kuma-004-uis-service](./PLAN-service-uptime-kuma-004-uis-service.md).

## 2. Observability went from installed to working

[INVESTIGATE-system-observability](../backlog/INVESTIGATE-system-observability.md)
measured the starting point: 11 components, ~4 GB of RAM, **zero** alert rules,
**zero** log shippers, and a Loki holding only its own canary traffic. Monitoring
was installed; nothing was monitored.

By 11 August:

- **11 baseline alert rules** delivering to Telegram
- **Alloy** shipping container logs into Loki
- **The hypervisor and the external database** scraped, so capacity is visible
  outside the cluster
- **External scrape targets declared** in `.uis.extend/`, not hardcoded
- **A PostgreSQL dashboard shipped with the service** — every metric counted in
  Prometheus *before* a panel was written, so no panel renders "No data"

## 3. Three defects where something existed but was not wired

A recurring shape, worth naming because it appeared four times in a month: **an
allowlist that new things never join, reporting success while missing the case.**

**A healthy stack could not deploy Grafana** (OBS-F6). Two plausible theories were
wrong before the cause turned up: `kubectl run --rm -i` returns `rc=0` with
**empty stdout** when the container outlives the attach. Every `until:` in that
playbook asserted on stdout, so a successful HTTP call read as a failure — and it
is load-dependent, which is why a *different* check failed on each deploy.
See [PLAN-service-grafana-deploy-gate-fix](../backlog/PLAN-service-grafana-deploy-gate-fix.md).

**Verify playbooks that nothing could run.** Registering one is a three-place
change; the guide named two. `031-test-alloy.yml` was reachable by no command at
all while the Alloy docs page told users to run it; uptime-kuma's was invisible to
`test-all`. All nine services audited afterwards.
See [PLAN-cli-verify-registration-fix](../backlog/PLAN-cli-verify-registration-fix.md).

**Alloy absent from its own website.** Docs page, sidebar entry and stack
membership were all added, but `services.json` and `stacks.json` are *generated*
and were never regenerated — so the site had no Alloy entry.
See [PLAN-service-alloy-verify-and-metadata-fix](./PLAN-service-alloy-verify-and-metadata-fix.md).

## 4. The external-service convention

The largest structural change. PostgreSQL and MinIO run **outside** the cluster in
production and **inside** it on a laptop, behind one identical interface.

The convention turned out to already exist, hand-written on one machine, and to be
better than anything that would have been designed: a proxy carrying the real
service's name and labels, so `PGHOST=postgresql.default` resolves identically in
both topologies and **no consumer changes at all**.

- Migration was invisible: `changed=0`, the pod never restarted
- Rebuild-from-nothing takes **14 seconds** from a four-line declaration
- MinIO then proved it generalises — twice the ports, twice the Services,
  different labels — which settled that it is **one template per service sharing a
  documented shape**, not one generic template
- The reference installation now has **zero hand-written proxies**

See [PLAN-system-external-services-001-proxy-convention](./PLAN-system-external-services-001-proxy-convention.md).

## 5. Principle 0 written down

*"Every service must be deployable on a developer's laptop"* is the platform's
central promise and was **stated nowhere**. Rancher Desktop appeared only as an
incidental default in playbook examples.

That absence is why Alloy was hand-installed, and why OpenBao, the registry
mirrors and the backup chain are still outside the platform. Nobody broke a rule —
there was not one. It is now Principle 0 in
[kubernetes-deployment.md](../../../contributors/rules/kubernetes-deployment.md)
and a hard requirement at the top of
[adding-a-service.md](../../../contributors/guides/adding-a-service.md).

## 6. Housekeeping that had accumulated

- **Vulnerabilities 99 → 2.** 26 Dependabot PRs, then npm `overrides` for two
  transitive roots Dependabot cannot reach. The remaining two are `image-size`
  with no published patch — a floor, not a backlog item.
- **46 broken documentation links → 0**, and the check that finds them made
  runnable. There is no Node on the workstation or in the provision-host
  container, so `npm run build` had been skipped every time it was asked for; it
  runs fine in a `node:20` container and that command is now in the guide.
- **1PRIORITY re-ranked** after three months of drift — it claimed 25
  investigations when there were 35, and the two driving all current work were
  missing entirely.

## 7. Open at the end of this period

Three investigations, all Tier 1, none built:

| | |
|---|---|
| [service-openbao](../backlog/INVESTIGATE-service-openbao.md) | The proxy convention does **not** fit it — TLS SANs cover no in-cluster name, `kubernetes` auth runs *into* the cluster, and ESO is the only consumer |
| The vault question | OpenBao backs **one** secret while `urbalurba-secrets` carries 54. The need is not demonstrated at current scale |
| [secrets-dev-to-production](../backlog/INVESTIGATE-secrets-dev-to-production.md) | `envsubst` renders an unset key as an empty string, silently; validation is a hardcoded allowlist; a `LocalDev` placeholder can reach production unwarned |

Observability itself is roughly half done — dashboards are still applied by hand
and probes are 0/27, both blocked on one artifact-convention decision.

## 8. After the main body of work

Two changes landed on 19 August that came from elsewhere:

- **Redis dropped its persistence PVC** — it is a cache
- **Monitors gained a `severity`**, routed to two ntfy priorities on the same
  topic, so the phone's Do Not Disturb decides what breaks through:
  *"the server declares severity, the phone decides disturbance."*

The second is the better fix to a problem that had been treated instance by
instance — three monitors were paging every 30 minutes through the night because
DHCP had moved the containers they watch, and separately a leftover debug pod kept
`PodNotReady` firing for five days. Correcting addresses fixes today; severity
routing fixes the class.
