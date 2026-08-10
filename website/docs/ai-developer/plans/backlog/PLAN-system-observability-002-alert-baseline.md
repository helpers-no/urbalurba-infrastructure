# Baseline alert rules, and somewhere for them to go

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: `uis stack install observability` produces a platform that **tells you
before things break**, not one that records that they did.

**Investigation**: [INVESTIGATE-system-observability](./INVESTIGATE-system-observability.md)
— finding **OBS-F1**, re-verified 2026-08-10 and unchanged

**Related**:
- [PLAN-service-uptime-kuma-003-alerting](./PLAN-service-uptime-kuma-003-alerting.md)
  — the external watchdog's alerting, already shipped. This is its in-cluster
  counterpart. It deliberately does **not** share the same channel; see Phase 1
- [PLAN-system-observability-001-log-collection](./INVESTIGATE-system-observability.md)
  — described in the investigation's Part 3, not yet a plan. Deliberately after
  this one; see Ordering below

**Priority**: High

---

## Problem

```
alerting_rules.yml in the prometheus-server ConfigMap:  {}      ← literally empty
Alertmanager pods running:                             1
Alertmanager present as a scrape target:               NO
```

⚠️ **Two corrections to how this was measured** (2026-08-11):

**There is no prometheus-operator.** UIS deploys the community `prometheus` chart,
not `kube-prometheus-stack`, so `monitoring.coreos.com` CRDs do not exist — 0 of
them. `kubectl get prometheusrule -A` returns 0 and always will, whatever rules
are configured. Rules live in the `prometheus-server` ConfigMap key
`alerting_rules.yml`, set from `serverFiles.alerting_rules.yml` in
`manifests/030-prometheus-config.yaml`. The investigation's "no alert rules" was
right; the way to check it was not.

**Alertmanager is not scraped**, so `alertmanager_notifications_failed_total` does
not exist. The component whose job is to tell you things are broken is the one
component nobody is watching. Fixing that is a prerequisite for task 1.5, not a
detail.

**Alertmanager is deployed, healthy, and evaluating nothing.** Every metric is
collected and stored; nothing looks at any of it until a human opens Grafana.

So today: a disk fills and you learn when it is full. Memory pressure surfaces
when the OOM killer fires. A pod crash-loops until someone notices the endpoint is
down. A certificate expires and TLS simply breaks.

The external watchdog ([PLAN-service-uptime-kuma-003](./PLAN-service-uptime-kuma-003-alerting.md))
already tells you the moment something *is* down. **Nothing tells you something is
becoming down**, which is the difference between a Tuesday-morning fix and a
Saturday-night outage.

:::danger This is the dangerous failure mode, not an absent one
An Alertmanager with zero rules is indistinguishable from one where everything is
fine. It consumes ~4 GB of RAM to produce silence, and silence is exactly what a
healthy platform also produces.
:::

## Ordering: why this comes before log collection

The investigation's Part 3 puts log collection first, on the grounds that Loki is
decorative without it. That is true. This plan still goes first, deliberately:

| | |
|---|---|
| **An alert reaches you.** A log query requires you to already be looking | decisive when the operator is remote or asleep |
| Alertmanager is **already running and idle** | only rules and routing are missing — the least work for the most coverage |
| Logs answer *why*; alerts answer *whether* | you can `kubectl logs` after the fact. You cannot recover a notification you never received |

⚠️ **The counter-argument is real and should be revisited**: once applications are
running, logs and app telemetry matter more than platform alerts do today, and
retrofitting a pipeline under running apps is worse than having it ready. If
application work starts before this lands, reorder.

---

## Phase 1: Delivery — somewhere for alerts to go

Rules without a receiver are a dashboard nobody opens. Do this first, so every
rule added afterwards is immediately verifiable.

### ⚠️ Decided by measurement: use a receiver Alertmanager supports natively

The first draft said "reuse ntfy, it is already proven for the watchdog". **That
was wrong, and testing it is what showed why.**

Measured on the deployed Alertmanager (`v0.33.1`):

```
native receivers: discord_configs  msteams_configs  pushover_configs
                  slack_configs    telegram_configs  webex_configs
ntfy:             not supported
```

And ntfy cannot format Alertmanager's payload itself — verified against ntfy.sh:

| Attempt | Result |
|---|---|
| POST the webhook JSON as-is | HTTP 200, and the phone receives **raw JSON** |
| `${.alerts[0]...}` placeholders | delivered **literally**, unsubstituted |
| `{{...}}` with `X-Template` | **HTTP 400** |

So ntfy would require a bespoke translator sitting in the alert path.

**That is the wrong place for hand-written code.** A translator that dies takes
alerting with it, and produces *silence* — which is indistinguishable from a
healthy platform. It would reintroduce, inside the alerting mechanism itself, the
exact failure this plan exists to remove.

**Principle: never put bespoke code in the path that tells you things are broken.**
Each tool uses its own native channel — Uptime Kuma has a native ntfy provider and
keeps using it; Alertmanager uses one of its own.

⚠️ **Needs a decision before implementing**, because it requires an app and an
account only the operator can create:

| Option | Cost | Setup |
|---|---|---|
| **Telegram** *(suggested)* | free | a bot via BotFather, then a chat id |
| **Pushover** | $5 once, per platform | an account and an app token |
| Discord / Slack | free | a webhook URL in a server you control |

Two apps on the phone is the price of zero bespoke code in either alert path. It
also keeps "the platform is unreachable" (ntfy, from the watchdog) visually
separate from "a disk is filling" (the other channel) without any configuration.

### Tasks

- [ ] 1.1 Route Alertmanager through a **natively supported** receiver — no
      translator, no webhook shim
- [ ] 1.2 Credentials from `urbalurba-secrets`. Absent ⇒ rules still deploy,
      delivery is skipped, and the deploy **says so loudly** rather than being
      quietly silent
- [ ] 1.3 Keep it distinct from the watchdog's channel, so an
      "everything-is-unreachable" alert cannot be lost among routine ones
- [ ] 1.4 Group and throttle: `group_by` on alertname + namespace, `group_wait`
      ~30s, `repeat_interval` ~4h, so a broad failure is one notification and not
      forty
- [ ] 1.5 ⚠️ **Add Alertmanager as a scrape target first — it is not one today**,
      which is why `alertmanager_notifications_failed_total` does not exist. Then
      alert on it. Uptime Kuma was found to make a single delivery attempt with no
      retry, losing a real alert to a transient timeout; assume Alertmanager can
      fail the same way. Until it is scraped, a silent notifier is invisible

### Validation

Fire a deliberately-true rule (`vector(1) > 0`). A **readable** notification
arrives on a real device — not raw JSON, not a literal template placeholder, not
nothing. All three of those were observed while choosing the receiver.

---

## Phase 2: Rules that earn their place

Every rule must answer *"what would I do about this?"*. Anything that cannot is
noise, and noise trains people to ignore alerts — the same lesson the watchdog's
sleeping-Mac monitors taught.

### Tasks

- [ ] 2.1 **Capacity, with warning time** — the whole point of this plan:
      - PVC above 85% `for: 10m`, and separately **predicted full within 24h**
        (`predict_linear`), which is the one that gives you a working day's notice
      - node filesystem above 85%
      - node memory pressure
- [ ] 2.2 **Workload health**:
      - pod crash-looping (`kube_pod_container_status_restarts_total` rate)
      - pod not ready `for: 15m` — long enough to ignore ordinary rollouts
      - deployment replicas unavailable `for: 15m`
      - node not ready `for: 5m`
- [ ] 2.3 **The stack itself**: `up == 0` for any scrape target, and
      Prometheus/Alertmanager config-reload failures. A monitoring stack that has
      stopped scraping must say so; that is this plan's own version of *absence
      renders as green*
- [ ] 2.4 **Certificate expiry** — within 14 days. Cheap, and it removes a whole
      class of self-inflicted outage
- [ ] 2.5 Every rule carries `summary`, `description` and a **runbook hint**. An
      alert that does not say what to do is a puzzle delivered at 3am
- [ ] 2.6 Severity split: `warning` (has slack — fix in hours) vs `critical`
      (acting now). Only `critical` should be able to wake someone

### Validation

```bash
# NOT `kubectl get prometheusrule` - there is no operator, so that is always 0.
kubectl get cm prometheus-server -n monitoring \
  -o jsonpath='{.data.alerting_rules\.yml}' | head    # must not be "{}"
```

Metrics the rules depend on were confirmed present before writing them, so none
is an alert that can never fire:

```
kube_pod_container_status_restarts_total  57    kubelet_volume_stats_used_bytes  14
kube_pod_status_ready                    132    node_filesystem_avail_bytes       5
kube_node_status_condition                12    node_memory_MemAvailable_bytes    1
kube_deployment_status_replicas_unavailable 31  up                               18
prometheus_config_last_reload_successful   1    alertmanager_notifications_failed_total  ABSENT
```

Stop a deployment; a firing alert is visible in Alertmanager within ~2 minutes and
arrives on the device.

⚠️ **Then leave it alone for 48h and count false alarms.** A rule set that pages
for normal operation is worse than none. If something fires that needed no action,
it is a defect in this plan, not in the platform.

---

## Phase 3: Deliberately not here

Recorded so the boundary is explicit rather than forgotten:

- **Backup freshness** — "last successful backup older than N hours" is arguably
  the single most valuable alert a self-hosted platform can have, and nothing
  produces it. It belongs to `PLAN-004-external-targets` because the signal comes
  from outside the cluster. **The external watchdog already covers this** via push
  heartbeats, so it is not a live gap — but it will need reconciling so the two do
  not both page for the same thing
- **Per-service rules** (`postgresql` connection saturation, `redis` evictions) —
  `PLAN-003-service-dashboards`, shipped with each service
- **Log-based alerting** — needs `PLAN-001-log-collection` first

---

## Acceptance Criteria

- [ ] `uis stack install observability` yields a non-empty rule set
- [ ] A capacity problem is alerted **before** it becomes an outage
- [ ] Alerts reach a real device, readable, on a topic separate from the watchdog's
- [ ] A missing topic degrades to "rules but no delivery", loudly, never silently
- [ ] Prometheus failing to scrape raises an alert about itself
- [ ] 48 hours of normal operation produces **zero** alerts needing no action
- [ ] Every alert states what to do about it

---

## Implementation Notes

**Each tool uses its native channel.** The tempting design was one notification
technology for everything. Measurement killed it: Alertmanager has no ntfy
receiver, and ntfy cannot format Alertmanager's payload, so unifying them means
writing a translator and placing it in the alert path. A component whose failure
produces silence does not belong there. Two apps, both driven by upstream-tested
code, beats one app plus a bespoke hop.

**Prefer `predict_linear` over a static threshold for disks.** "85% full" tells you
where you are; "full in 6 hours" tells you whether to care. On this installation
the pools are at 5% and 18%, which is exactly when to add the rule — a threshold
added while something is already full is an incident report, not monitoring.

**`for:` durations are the difference between alerting and noise.** A pod not
ready for 15 seconds is a deployment. For 15 minutes it is a problem. Every rule
here needs a duration chosen on that basis, and the 48h quiet period in Phase 2 is
what proves the choices.

**Do not adopt a large upstream rule bundle wholesale.** `kube-prometheus-stack`
ships ~100 rules tuned for large multi-tenant clusters; on a single-node k3s many
are meaningless or permanently firing, and a permanently-firing alert is a muted
alert. Start with the list above, add rules when something actually breaks and the
alert would have helped.

---

## Files to Modify

- `manifests/030-prometheus-config.yaml` — `serverFiles.alerting_rules.yml` for
  the baseline group, an Alertmanager scrape job, and `alertmanager.config`
- `ansible/playbooks/` — the prometheus setup playbook, to apply both
- `provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template`
  — credentials for the chosen receiver
- `provision-host/uis/templates/secrets-templates/00-common-values.env.template`
- `website/docs/services/observability/prometheus.md` — what alerts exist, how to
  add one, how to silence one
