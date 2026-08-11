---
title: Grafana Alloy
sidebar_label: Alloy
description: Ships container logs into Loki — without it, Loki is deployed and empty
---

# Grafana Alloy

Collects container logs from every node and ships them to Loki.

| | |
|---|---|
| **Category** | Observability |
| **Service ID** | `alloy` |
| **Namespace** | `monitoring` |
| **Image** | `grafana/alloy:v1.13.1` |
| **Chart** | `grafana/alloy` |
| **Requires** | [Loki](./loki.md) |
| **Website** | https://grafana.com/docs/alloy/ |

## Why you need it

**Loki without a collector is deployed, healthy, and empty.** It holds only its
own canary traffic, Grafana's Loki datasource returns nothing useful, and a log
search comes back blank — which reads as *"nothing happened"* rather than
*"nothing is being collected"*.

That distinction is the whole reason this service exists as its own entry rather
than being folded into Loki: the store and the collector fail differently, and
only one of them fails visibly.

## Deploy

```bash
uis deploy loki      # the store first
uis deploy alloy     # then the collector
```

Deploying Alloy without Loki is not fatal — it will retry — but the playbook warns
you, because an agent shipping into nothing looks perfectly healthy.

It runs as a **DaemonSet**, because container logs live on nodes.

## Verify

```bash
uis verify alloy
```

This checks three things, and the second is the one that matters:

1. The pods are Running
2. **Loki reports real namespaces** — proof that logs are actually arriving, not
   merely that the agent started
3. No high-cardinality labels have crept back in

:::warning A running agent is not a working pipeline
A DaemonSet can be perfectly healthy while shipping nothing: wrong labels, an
unreachable Loki, a file scanner that matched no paths. Checking that the pod is
Running proves only that the process started. Always assert on what arrived at
the other end.
:::

## Querying your logs

Labels are what you filter on:

```logql
{namespace="ai"}                          everything in a namespace
{namespace="ai", container="litellm"}     one container
{app="litellm"} |= "error"                by app label, filtered
```

Available labels: `namespace`, `pod`, `container`, `node`, `app`.

## Why the label set is deliberately small

Loki indexes label **values**, so a label that takes a new value often makes the
index grow without bound. This is the most common way a working Loki install
becomes an unusable one.

:::danger Never add a high-cardinality label
No pod UID, no request id, no trace id, no user id. Put those in the log **line**,
where they are searchable with `|=` at no index cost.
:::

The log source adds an `instance` label by itself, formatted
`<namespace>/<pod>:<container>`. It embeds the pod name, so every deploy mints a
new value. The shipped config removes it — and `uis verify alloy` fails if it
comes back, because this is the kind of regression that degrades Loki slowly and
silently rather than breaking it.

Getting rid of it needs a target-level rule with an empty replacement.
`stage.label_drop` in the processing pipeline does **not** work, because the
source sets the label outside that label set:

```
rule {
  target_label = "instance"
  replacement  = ""
}
```

## Retention

Retention is Loki's setting, not Alloy's — see [Loki](./loki.md). Two things worth
knowing once logs actually start arriving:

- The default window was chosen when Loki held nothing. **If it is shorter than
  the time between a failure and someone investigating it, the logs you want are
  already gone** and the pipeline is decorative.
- Retention is time-based with no size cap, so a busy day can fill the disk
  before the window elapses.

## Scope: logs only

Alloy is a distribution of the OpenTelemetry Collector and *can* also handle
metrics and traces, replacing the standalone [OTLP Collector](./otel.md) and
taking the stack from five components to four.

UIS deliberately does not do that yet. The collector carries the metrics
remote-write path into Prometheus and it works; replacing it in the same change
that introduces log collection would put two failure domains in one step and make
any regression hard to attribute.

## Remove

```bash
uis undeploy alloy
```

Log **collection** stops immediately. Logs already in Loki stay until its own
retention expires them.
