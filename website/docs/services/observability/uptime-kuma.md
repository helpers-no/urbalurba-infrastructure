---
title: Uptime Kuma
sidebar_label: Uptime Kuma
---

# Uptime Kuma

External availability watchdog. Answers *"is it up, and did the job run?"*

| | |
|---|---|
| **Category** | Observability |
| **Service ID** | `uptime-kuma` |
| **Namespace** | `monitoring` |
| **Image** | `louislam/uptime-kuma:2.5.0` |
| **Port** | 3001 |
| **URL** | `http://uptime-kuma.localhost` |
| **Website** | https://uptime.kuma.pet |

## :warning: Run this outside the platform it monitors

Uptime Kuma is only useful on a host that is **not part of the platform it
watches**. A monitor inside a cluster cannot report that cluster being down —
which is the one situation you need it for.

`./uis deploy uptime-kuma` will happily install it onto the cluster you intend
to monitor. It will look healthy and it will be useless when it matters. **UIS
has no way to express "deploy this elsewhere"**, so this is a convention you
have to honour, not a rule the tooling enforces.

A reasonable arrangement: a small always-on machine — a Raspberry Pi, a NAS, a
free-tier cloud VM — that runs nothing else you care about.

## What it is for, and what it is not

It does **not** replace Prometheus, Grafana and Loki. The two answer different
questions:

| Question | Answered by |
|---|---|
| Is the endpoint responding? | Uptime Kuma |
| Is the cluster itself reachable? | Uptime Kuma — the in-cluster stack dies with it |
| Did the nightly backup actually run? | Uptime Kuma push/heartbeat monitor |
| Why is p99 latency up since Tuesday? | Prometheus / Grafana |
| What did the pod log before it crashed? | Loki |

There is deliberate overlap on endpoint probing — `blackbox_exporter` does the
same thing. That is the cheapest part of either system, and duplicating it is
sensible redundancy at the one layer where a single point of failure is
unacceptable.

### Heartbeat monitors are the part nothing else provides

A **push monitor** gives you a URL. A job calls it on success. If the call stops
arriving within the expiry window, you get alerted.

That detects the *absence of work*, which metric-based alerting handles badly:
nothing crashes, no error rate spikes, work simply stops. Backups that silently
stop and pipelines that quietly die are the classic cases — the failure mode
where a dashboard shows all green for hours.

## Deploy

```bash
./uis deploy uptime-kuma
```

Then open the URL and complete the **first-run wizard** — choose SQLite and
create the admin account. This is browser-only; no monitors can exist until it
is done.

## Verify

```bash
./uis verify uptime-kuma
```

Checks that the UI responds, that the page really is Uptime Kuma, that
`/app/data` is a mounted volume rather than container filesystem, and that the
IngressRoute exists.

These prove the service *runs*. They cannot prove it is *useful* — that depends
on where you deployed it and on monitors existing.

## Remove

```bash
./uis undeploy uptime-kuma                                  # keeps the data
ansible-playbook 230-remove-uptime-kuma.yml -e remove_pvc=true   # deletes it
```

The PVC is kept by default. It holds monitor definitions, notification
configuration and the entire uptime history, none of which is reproducible.

## Storage

Embedded SQLite on a `ReadWriteOnce` volume, deployed as a StatefulSet so there
is exactly one writer. It uses the cluster's default StorageClass.

Heartbeats are small but frequent, so on flash-backed storage set a sensible
check interval (60s rather than 20s) and trim retention. On a Raspberry Pi or
similar, prefer putting the volume on something other than the boot card — not
for speed, but so that wearing it out costs a replaceable device rather than a
rebuild.

## No secrets

Uptime Kuma creates its admin account through the first-run wizard and stores it
in its own database. Nothing is read from `urbalurba-secrets`.

Notification credentials (Telegram token, SMTP password, ntfy topic) are entered
in the UI and live in the same database. Treat that volume as sensitive and back
it up.

## Suggested first monitors

Derived from failures that actually happened on the reference deployment:

| Monitor | Type | Catches |
|---|---|---|
| k3s API `:6443` | TCP | the cluster being down — the in-cluster stack cannot report this |
| Hypervisor UI | TCP/HTTP | the host being down |
| PostgreSQL `:5432` | TCP | the database being unreachable |
| Object storage `/minio/health/live` | HTTP | storage being down |
| Any API gateway | HTTP + **keyword** | a 200 with a broken backend — status codes alone lie |
| `backup-nightly` | **Push**, ~26 h expiry | a backup that silently stopped |
| `worker-heartbeat` | **Push**, ~15 min expiry | a pipeline that stalled with nothing crashing |

Use keyword matching, not just status codes: a gateway can return 200 while its
database is dead.

Set the expiry on daily heartbeats a couple of hours beyond the schedule so a
late run does not page, and avoid windows that straddle the daylight-saving
transition.

## Who watches the watchdog

If Uptime Kuma dies, everything looks fine forever. Options:

- **Dead-man's switch** — it pushes a heartbeat to a free external service,
  which alerts if the push stops. The only thing that catches the whole host
  going away.
- **Mutual monitoring** — the in-cluster Prometheus probes Uptime Kuma. The one
  place where duplication is clearly correct.
