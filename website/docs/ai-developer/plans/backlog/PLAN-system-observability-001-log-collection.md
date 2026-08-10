# Ship container logs to Loki

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Active — deployed and collecting; retention decision (Phase 3) outstanding

**Goal**: Logs from every pod are searchable in Grafana, automatically, so that
when an alert fires there is something to look at.

**Investigation**: [INVESTIGATE-system-observability](./INVESTIGATE-system-observability.md)
— finding **OBS-F2**, re-verified 2026-08-11 and unchanged

**Related**: [PLAN-system-observability-002-alert-baseline](./PLAN-system-observability-002-alert-baseline.md)
— shipped. Alerts now fire; this is what makes them diagnosable

**Priority**: High

---

## Problem

Loki is deployed, healthy, and holds nothing.

```
labels present:        pod, service_name, stream
service_name values:   ["unknown_service"]      ← its own canary
pod values:            (none)
log-shipper DaemonSets: 0
```

**Nothing ships container logs to it.** Grafana has a Loki datasource that
returns nothing useful; Loki consumes storage to hold its own test traffic.

This is the other half of the alerting work. `PLAN-002` means you now find out
*that* something is wrong. Without logs, the next step is `kubectl logs` against a
pod that may have already been replaced — and a crash-looping container's previous
logs are exactly the ones you need and the first ones to disappear.

## Decision: Grafana Alloy

Settled in the investigation and not re-opened here. **Promtail reached
end-of-life on 2 March 2026**, so it is not a candidate. Alloy is its successor
and a vendor-neutral OTel Collector distribution.

⚠️ **Scope: logs only.** Alloy *can* also replace the standalone OTel Collector,
taking the stack from five components to four, and the investigation notes this.
This plan deliberately does not do that. The collector currently carries the
metrics remote-write path into Prometheus, which is working; replacing it in the
same change as introducing log collection means two failure domains in one step,
and a regression in either would be hard to attribute. Consolidation is a
follow-up, once logs are known good.

---

## Phase 1: Collect

### Tasks

- [x] 1.1 Deploy Alloy as a **DaemonSet** ✓ — logs are per-node, so it must run
      where the containers do
- [x] 1.2 Discover pods via the Kubernetes API and tail their container logs ✓
- [x] 1.3 Write to the existing Loki gateway ✓
- [x] 1.4 Image pinned to `v1.13.1` ✓
- [x] 1.5 Requests 100m/128Mi, matching the collector ✓

### Validation

✅ **Done.** Before: Loki held only `service_name=unknown_service` and no `pod`
values. After: nine real namespaces — `ai`, `authentik`, `csi-proxmox`,
`default`, `external-secrets`, `kube-system`, `monitoring`, `tailscale`,
`temporal` — and `{namespace="ai",container="litellm"}` returns that container's
log lines.

⚠️ **One anomaly, unexplained and recorded rather than rationalised.** A line
reading `failed to create fsnotify watcher: too many open files` appeared in Loki
labelled `container=litellm`. That container's own logs contain zero occurrences,
it has zero restarts and no previous instance, Alloy's own logs contain none
either, and the node's inotify usage is 1 of 128 instances — so nothing is
actually exhausted. Where the line came from is not established. It has not
recurred. Worth watching, and worth not inventing a cause for.

---

## Phase 2: Labels that make logs findable

Labels are the whole ergonomics of Loki. Get them wrong and you have a very
expensive `grep`.

### Tasks

- [x] 2.1 Labelled with `namespace`, `pod`, `container`, `node`, `app` ✓
- [x] 2.2 ⚠️ **No high-cardinality labels** ✓ — but this took three attempts and
      is worth recording, because the obvious config is not enough.

      `loki.source.kubernetes` adds `instance` by itself, derived as
      `<namespace>/<pod>:<container>`. It embeds the pod name, so every deploy
      mints a new label value and the index grows without bound — precisely what
      this task forbids, arriving by default.

      Adding relabel rules does **not** help: they add labels, they do not remove
      the ones the source supplies. `stage.label_drop` in the process pipeline
      did **not** work either (verified — `instance` was still present in streams
      written afterwards), because the source sets it outside that label set.

      What works is blanking it at the target level, where an empty replacement
      drops the label:

      ```
      rule {
        target_label = "instance"
        replacement  = ""
      }
      ```

      Confirmed by querying `/labels` over a 90-second window containing only
      post-fix data.
- [x] 2.3 Raw log line kept as the message ✓

### Validation

`{namespace="ai", container="litellm"}` selects exactly that container's logs.

---

## Phase 3: Retention, honestly

### Tasks

- [ ] 3.1 Confirm what Loki's retention actually is once real volume arrives.
      It is currently `24h`, which was set when Loki held nothing
- [ ] 3.2 ⚠️ **Decide whether 24h is enough.** An alert that fires overnight and
      is looked at the next evening may be looking for logs that have already
      been deleted. Retention shorter than the time between failure and
      investigation makes the whole pipeline decorative
- [ ] 3.3 Check the volume against the disk before extending it. Retention is
      time-based with **no size cap** (`retentionSize` appears nowhere), so a
      busy day can fill the disk before the window elapses

### Validation

Measured log volume per day, and a retention window justified against it rather
than guessed.

---

## Acceptance Criteria

- [ ] `uis stack install observability` results in logs from every namespace
      being queryable in Grafana, with no manual steps
- [ ] Label values include real workloads, not only `unknown_service`
- [ ] No high-cardinality labels
- [ ] Retention is a decision, with the numbers written down
- [ ] The metrics pipeline through the OTel Collector still works — verified, not
      assumed, because this change lands next to it

---

## Implementation Notes

**This is a greenfield install, not a Promtail migration.** UIS has no Promtail
to convert — that absence *is* OBS-F2.

**Alloy emits different metrics from Promtail or the collector.** Any dashboard or
alert built on collector metrics will need updating. Nothing in
`PLAN-002`'s rule set depends on them today, which is worth keeping true.

**Logs are the diagnosis half, not the detection half.** Detection is
`PLAN-002` and the external watchdog. It is worth being clear about which problem
each component solves, because a stack that collects everything and alerts on
nothing is where this platform started.

---

## Files to Modify

- `manifests/` — Alloy helm values
- `ansible/playbooks/` — a setup playbook, and registration in the observability stack
- `provision-host/uis/services/observability/` — the service definition
- `website/docs/services/observability/` — a page for it, and the stack overview
