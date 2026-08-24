---
title: "PodNotReady alerts forever on pods that have finished"
status: backlog
type: PLAN
area: observability
severity: medium
created: 2026-08-24
---

# `PodNotReady` alerts forever on pods that have finished

**Filed from PR #250**, opened 2026-08-16 and closed unmerged on 2026-08-24
without ever being reviewed. The change is small and still valid; it is parked
here rather than left as a stale PR against a `main` that has moved a long way
since. **The defect is still present on `main`.**

## The defect

A completed pod reports `ready=false` **forever**, so any one-off pod that
outlives its cleanup fires `PodNotReady` permanently.

`manifests/030-prometheus-config.yaml` today:

```yaml
- alert: PodNotReady
  expr: |
    kube_pod_status_ready{condition="false"} == 1
  for: 15m
```

Nothing excludes `Succeeded` or `Failed`.

## It has already happened, and it reached a human

On 2026-08-11 a `kubectl run --rm` debug pod lost its attach — the same attach
race fixed in the Grafana probes that day — so `--rm` never ran. The pod stayed
`Succeeded` in `monitoring/`. `PodNotReady` fired at 20:54 and **kept firing to
Telegram for five nights**, until the pod was deleted on 2026-08-17.

The alert was correct about the condition and wrong about it mattering.
**Litter is not an incident**, and an alert that pages for litter teaches people
to ignore the alert.

## The fix

```promql
kube_pod_status_ready{condition="false"} == 1
unless on(namespace, pod)
kube_pod_status_phase{phase=~"Succeeded|Failed"} == 1
```

Four lines in `manifests/030-prometheus-config.yaml`, plus the comment recording
why.

## Already verified once

Recorded in the closed PR: with a deliberately created `Succeeded` pod present,
the **original** expression matched it and the **corrected** one returned zero.
The proof pod was removed afterwards.

That means the promql is not a guess — but it predates the build/verify
separation, so it has never been through the tester loop and should be, however
small it is.

## Why this keeps mattering

The class of pod that triggers it is **routine now, not exotic**. Verify
playbooks create probe pods; Jobs leave pods behind for their
`ttlSecondsAfterFinished`; and a Job deleted without a propagation policy
**orphans** its pods entirely — which is exactly what made browserless' undeploy
fail on 2026-08-24. Every one of those is a finished pod sitting in a namespace
looking not-ready.

So the alert will keep firing on normal platform activity until this lands.

## Scope

Deliberately just the exclusion. Two adjacent questions are **not** in scope and
should be asked separately:

1. Should finished pods be cleaned up more aggressively, so the alert has less to
   trip over? (Partly addressed already — the browserless fix made a verify Job
   take its pods with it.)
2. Do any *other* alerts in `030-prometheus-config.yaml` share this shape —
   correct about a condition, wrong about it mattering?

## Related

- The `kubectl run --rm` attach race that created the original pod is the same
  idiom covered by
  [[INVESTIGATE-system-verification-playbooks-usage]]
- Original PR: #250 (closed unmerged, superseded by this file)
