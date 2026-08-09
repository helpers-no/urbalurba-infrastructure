---
title: Uptime Kuma
sidebar_label: Uptime Kuma
description: The external watchdog - what it monitors, how monitors get created without you writing any, and the two ways to run it
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

Deploying it also deploys **AutoKuma**, which turns monitor definition files into
monitors. It is part of this service, not a separate thing to install.

## :warning: Run this outside the platform it monitors

A monitor inside a cluster cannot report that cluster being down — which is the
one situation you need it for.

`./uis deploy uptime-kuma` will happily install it onto the cluster you intend to
monitor. It will look healthy and be useless when it matters. **UIS cannot
express "deploy this elsewhere"**, so this is a convention you honour, not a rule
the tooling enforces.

For local development that does not matter and you should ignore it — see the
developer path below.

## You do not write monitors

This is the part worth understanding, because it is different from how most
people use Uptime Kuma.

Both halves of a monitor are already known to UIS:

| Needed | Where it comes from |
|---|---|
| **How** to probe — path, keyword, which secret | ships with the service, as a probe artifact |
| **Where** the service is | discovered from the `Service` and `Ingress` that `uis deploy` created |

So you deploy services, deploy the watchdog, and run:

```bash
uis monitors apply
```

Nothing asks you for a hostname. You never had to know one to deploy the service,
and you should not have to know one to monitor it.

```
probe artifacts (ship with each service)
        +
cluster discovery (Service / Ingress)
        │  uis monitors apply
        ▼
Secret  uptime-kuma-monitors
        │  AutoKuma reconciles
        ▼
   Uptime Kuma  ──alerts──▶  your phone
```

### The three commands

```bash
uis monitors render    # what would be monitored. Changes nothing
uis monitors apply     # write the definitions, restart AutoKuma, attach alerting
uis monitors check     # compare intent against what Kuma is actually running
```

`check` is not decoration. AutoKuma reconciles continuously, so drift heals
itself — which means a **stopped** AutoKuma looks exactly like a healthy one.
`check` compares against Kuma itself, not just against the definitions.

---

## Path 1 — a developer on Rancher Desktop

You have one cluster. Uptime Kuma runs in it. That is fine: you are not trying to
detect your laptop being off.

```bash
uis deploy uptime-kuma
uis monitors apply
```

That is the whole thing. Open `http://uptime-kuma.localhost`, log in as `admin`
with the shared `DEFAULT_ADMIN_PASSWORD`, and the services you have deployed are
already listed.

Because the watchdog is inside the cluster, endpoints resolve to in-cluster DNS:

```
http://litellm.ai.svc.cluster.local:4000/v1/models
postgresql.default.svc.cluster.local:5432
```

**You get more coverage than production does**, not less: in-cluster-only
services like PostgreSQL are reachable here and are not reachable from an
external watchdog.

Deploy another service and re-run `uis monitors apply`.

## Path 2 — an ops engineer running it in production

The watchdog runs on a separate machine — a Pi, a NAS, a small VM — with its own
tiny cluster. The services run somewhere else. So discovery has to read one
cluster and write to another:

```bash
uis monitors apply --from production --to watchdog
```

| | |
|---|---|
| `--from` | where the services are. **Read-only** |
| `--to` | where Uptime Kuma runs. Written to |

Omit both and you get Path 1 behaviour.

### Give discovery a read-only identity

Do **not** copy an admin kubeconfig onto the watchdog host. Discovery needs three
read verbs on three resource types; an admin credential would put full control of
your platform on the machine whose entire purpose is to sit outside it.

```bash
kubectl --context production apply -f manifests/230-uptime-kuma-discovery-rbac.yaml
```

That creates a `monitor-discovery` ServiceAccount which can list services,
endpoints and ingresses, and nothing else. Add it to the watchdog host's
kubeconfig as the `--from` context.

Verify it is as powerless as intended:

```bash
kubectl --context production get secrets -A    # must be Forbidden
```

### What resolves, and what cannot

From outside the cluster, in order of preference:

| | Gives |
|---|---|
| `Ingress` with `ingressClassName: tailscale` | a real FQDN with a real certificate — the best case |
| A shim `Service` whose Endpoints point outside the pod network | the external address, straight from the Endpoints object |
| `LoadBalancer` | its external address |
| **ClusterIP only** | **nothing.** Not reachable from another machine |

That last row is reported, never silently dropped:

```
NOT MONITORED (1):
  postgresql: only reachable inside the cluster (ClusterIP). An external
  watchdog cannot probe it - expose it, give it a shim, or rely on the
  services that depend on it failing their own probes
```

A deployed service that quietly gets no monitor is indistinguishable from one
that is passing. Read that list.

---

## Targets UIS did not deploy

A hypervisor, a NAS, a laptop, a printer, a nightly job. UIS cannot discover
these because it did not create them, so they go in
`.uis.extend/monitors.yaml`:

```yaml
defaults:
  interval: 60
  maxretries: 2
  notify: true

monitors:
  - name: hypervisor-ui
    type: port
    hostname: 192.168.1.10
    port: 8006
    why: If this is down, everything running on it is too.

  - name: vault
    type: http
    url: https://192.168.1.20:8200/v1/sys/health
    ignore_tls: true                       # internal certificate
    accepted_statuscodes: ["200-299"]      # a SEALED vault answers 503
    why: Sealed counts as down - it is useless to consumers even when running.

  - name: heartbeat-nightly-backup
    type: push
    interval: 93600                        # 26h - headroom for a late run
    why: Catches a backup that silently stopped.
```

**This file is empty or absent on a stock install.** If you find yourself adding
something UIS *did* deploy, that is a bug in discovery or a missing shim — and
`uis monitors` will refuse it as a duplicate rather than let two definitions
silently overwrite each other.

`why:` is not decoration. A monitor nobody can justify is a monitor nobody
maintains.

## Heartbeats — the part nothing else provides

A push monitor gives you a URL. A job calls it **after** its success check. If
the call stops arriving inside the expiry window, you are alerted.

That detects the *absence of work*, which metric alerting handles badly: nothing
crashes, no error rate moves, work simply stops.

```bash
# in a shell script under `set -e`, the last line is the success check
curl -fsS "https://kuma.example/api/push/<token>?status=up&msg=ok"
```

```ini
# in a systemd unit - ExecStartPost only runs if ExecStart exited 0
ExecStartPost=/usr/local/sbin/kuma-push.sh <token> "backup ok"
```

:::danger Never push unconditionally
A job that calls its heartbeat regardless of outcome reports success when it
fails. That is worse than no heartbeat, because it manufactures confidence.
:::

**Tokens are derived, not random** — `HMAC-SHA256(salt, monitor name)` from
`uptime-kuma-push-salt`. A rebuilt watchdog therefore reissues *identical* URLs
and no job needs rewiring. Back that salt up: lose it and every heartbeat caller
is silently orphaned, still exiting 0 while nothing records that it ran.

## Alerting

Set a topic and alerting is configured on deploy:

```bash
UPTIME_KUMA_NTFY_TOPIC=uis-<something-long-and-random>
```

Then subscribe to the same topic in the [ntfy](https://ntfy.sh) app. Leave it
empty and the watchdog still monitors — it just tells nobody, and says so during
deploy rather than being quietly silent.

:::warning On public ntfy.sh the topic name *is* the credential
Anyone who learns it can read your alerts and publish fake ones. Use a long
random value, or self-host.
:::

Every monitor pages by default. Set `notify: false` on anything whose failure is
not both real and actionable:

- a laptop or workstation that **sleeps** — it will page every nap
- a heartbeat whose **job does not exist yet** — it pages once and stays down

An alert you learn to swipe away is worse than no alert: it trains you to ignore
the real one.

## Adding a probe to a service

For service authors. Create `provision-host/uis/services/<category>/probes/<id>.yaml`:

```yaml
# Only what is true of EVERY install of this service.
# No hostnames - those are discovered. No secret values - name the key.
service: my-service-web        # only if the k8s Service name differs from the id
probes:
  - id: gateway
    type: http                 # http | tcp
    path: /healthz
    keyword: ready             # match content, not just status
    auth: bearer:MY_API_KEY    # a KEY in urbalurba-secrets, never a value
    interval: 60
    maxretries: 2
```

⚠️ **`service:` matters.** The probe is matched to a Kubernetes Service by name.
If your service id is `temporal` but the Service is `temporal-web`, omitting this
means the probe matches nothing and the service goes unmonitored **with no
error**.

⚠️ **Prefer a keyword to a status code.** A gateway can return 200 while its
database is dead, because the response never touched the database.

## Deploy, verify, remove

```bash
uis deploy uptime-kuma            # Kuma + AutoKuma + admin + retention + alerts
uis verify uptime-kuma
uis undeploy uptime-kuma          # keeps monitors, history, notification config
uis undeploy uptime-kuma --purge  # deletes all of it
```

**No first-run wizard.** `UPTIME_KUMA_DB_TYPE=sqlite` skips the database screen,
and the playbook seeds the admin account — `needSetup` is just "is the user table
empty?". Seeding is idempotent, so redeploying never clobbers a password you
changed in the UI.

Use `--purge` when you want to prove an install works. Keeping the volume means
every reinstall after the first lands on existing state, so a broken
first-install path stays hidden.

## Storage and secrets

Embedded SQLite on a `ReadWriteOnce` volume, StatefulSet, one writer. History
retention defaults to 30 days rather than Kuma's 180, because a watchdog usually
runs on flash storage.

On a Pi or similar, put the volume somewhere other than the boot card — not for
speed, but so wearing it out costs a replaceable device rather than a rebuild.

| Key in `urbalurba-secrets` | |
|---|---|
| `uptime-kuma-admin-user` | `admin` |
| `uptime-kuma-admin-password` | inherits `${DEFAULT_ADMIN_PASSWORD}` |
| `uptime-kuma-push-salt` | derives heartbeat URLs — **back this up** |
| `uptime-kuma-ntfy-server` / `-topic` | the alert channel |

It shares the platform admin password rather than defining its own, so there is
one credential to rotate.

:::warning
Three things write to Kuma's own database, which is a private interface rather
than a published API: the admin seed, retention, and the alert channel with its
attachments. Kuma has no API for any of them. Each is guarded — the schema is
checked first, writes are insert-only, and each is verified afterwards rather
than assumed. Monitors are **not** in that list; AutoKuma owns those.
:::

## Who watches the watchdog

If Uptime Kuma dies you get silence, and silence looks exactly like health.

The arrangement that works: a **second machine** polls the watchdog and, if it
cannot reach it, alerts your phone **directly** — going through Kuma would be
pointless when Kuma is what is down. Latch the state so you get one alert, not a
storm, plus one on recovery.

⚠️ **That still does not cover everything.** Two machines in the same building
share a power cut and an internet outage. Full coverage needs something off-site:
a free dead-man's-switch service, or a cron job somewhere you do not own.

Decide where you put that boundary deliberately, rather than discovering it
during an incident.

## When something is wrong

The failure modes here are quiet ones, so check in this order:

| Symptom | Likely cause |
|---|---|
| `apply` succeeded, no new monitors | AutoKuma has not re-read the definitions. `apply` restarts it; a manual Secret edit does not |
| Monitor count doubled after a restart | `/data` is not persisted — it holds AutoKuma's id map |
| A monitor is DOWN with 401 | the probe's `auth:` key is missing from `urbalurba-secrets` |
| A deployed service has no monitor | read the `NOT MONITORED` list from `uis monitors render` |
| `check` reports drift that is not real | wrong `--from`/`--to` contexts |
| Everything green, nothing ever alerts | no channel configured, or `notify: false` |
