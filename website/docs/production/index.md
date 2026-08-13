---
title: Production
sidebar_label: Overview
sidebar_position: 1
---

# Running UIS in production

UIS is designed so the same stack runs on a laptop, on-premises and in the cloud.
That promise holds — but a production deployment differs from the developer
default in ways that are **architectural, not cosmetic**. This section describes
those differences once, platform-agnostically, and then links to a concrete guide
per platform.

The developer default optimises for *getting started in one command*. Production
optimises for *surviving things going wrong*. Everything below follows from that.

---

## The seven decisions that make a deployment production

### 1. State lives outside the cluster

Databases, object storage, the secret store and the image cache should **not** be
Kubernetes workloads in production.

Three independent reasons, each sufficient on its own:

- **Survivability** — a failed cluster upgrade, expired certificates or a broken
  CNI should not take your data offline. If the database is outside, you can still
  reach it while you repair Kubernetes.
- **Bootstrap** — the cluster needs secrets and images *to start*. Anything on the
  startup path cannot live inside the thing it starts. A vault in the cluster it
  protects, or a registry serving the images needed to run that registry, is
  circular.
- **Multiple clusters** — dev laptops, a second site and cloud targets all need
  the same database, object store and secrets. A component inside one cluster
  cannot serve the others.

In cloud this is natural (RDS, Cloud SQL, S3, Key Vault). On-premises it means
dedicated hosts or containers beside the cluster. Either way, **UIS services keep
consuming them by their usual in-cluster names** — the application does not change.

### 2. The management plane is always-on

`./uis` runs the provision-host container against a kubeconfig. In development
that is your laptop. In production the management plane should be a small
always-on host that holds the kubeconfigs for every target, so operating the
platform never depends on a workstation being awake — and so it works identically
whoever runs it.

It must be on the same overlay network as the clusters it manages, or it can only
reach what is on its LAN.

### 3. Real secrets, in a real store

The developer defaults are *known values*, shared publicly in this repository.
They are appropriate for a laptop and dangerous the moment a cluster is
internet-adjacent — which is one command away.

Production needs: generated per-install secrets, a store outside the cluster
(see #1), encryption at rest, and a rotation path. See the
[secrets guide](./secrets.md) for a working reference implementation.

### 4. A backup is a hypothesis until you have restored it

Backups that run successfully every night can still be useless. Verify by
restoring — and re-verify after any change to the chain.

A real example from the reference deployment: the database container ran `UTC`
while the host ran local time, so the dump job executed **three hours after** the
off-box backup meant to capture it. Every offsite copy held the *previous day's*
dump. Both jobs reported success every night. **Only a restore test found it.**

### 5. Observability must be able to wake someone

Deploying Prometheus, Loki, Tempo and Grafana is not observability. On the
reference deployment, after installing the full stack:

- `/api/v1/rules` returned `{"groups":[]}` — **zero alert rules**, so no condition
  could ever notify anyone;
- Loki contained only its own deployment test — **no log agent was installed**, so
  container logs were never collected;
- every Prometheus target was inside the cluster, so **the external database,
  object store, host and backups were unmonitored**.

Production needs alerts (starting with *"last successful backup older than N
hours"*), log collection, and targets outside Kubernetes.

### 6. Decide public versus private per service

Once ingress exists, **anything with a permissive route is on the internet**.
Admin UIs — Grafana, Temporal, object-store consoles, the identity provider —
generally should not be. Choose deliberately per service:

- **Private**: an overlay network (Tailscale/WireGuard) or VPN. Simple, and the
  network *is* the auth boundary.
- **Public**: a tunnel or load balancer **plus** authentication in front. If your
  identity provider integrates via reverse-proxy forward-auth, note that some
  exposure mechanisms bypass the proxy entirely and therefore bypass auth.

### 7. Anything on the startup path must be local

If a deployment must keep running when external providers are unreachable, then
nothing required to *start* a workload may depend on them. In practice:

| On the startup path | Consequence if remote-only |
|---|---|
| Container images | running pods survive; **any restart cannot pull** → the service stays down |
| Secrets | workloads cannot start |
| DNS / service discovery | resolution fails |

Cloud is then used for **reach** (public ingress) and **recovery** (offsite
backup) — never for running.

---

## The parity contract: what a developer must see

None of the above may break UIS's core promise — **a developer running Rancher
Desktop should be building against the same thing that will run in production.**
That promise is about the **interface**, not the topology.

### Must be identical (dev and production)

| | Why |
|---|---|
| Service names apps connect to (`postgresql.default:5432`, `minio.default:9000`, …) | application config must not change between environments |
| How an app receives secrets — an ordinary Kubernetes Secret | whether UIS templated it or an operator synced it from a vault is invisible |
| How an app requests storage — a PVC with no explicit class | the default class differs; the manifest does not |
| Ingress *mechanism* (Traefik routes) and the reverse-proxy version | see the warning below |
| `uis deploy` / `uis configure` behaviour and output | the same commands, the same connection JSON |

**`uis configure <service> --app <name>` is the mechanism that makes this work.**
It provisions per-app resources in *whichever* cluster it targets and returns both
a local and an in-cluster URL — so **application credentials are generated per
environment and never promoted**. Dev and production differ in values, never in
shape.

### May legitimately differ

| | Dev | Production |
|---|---|---|
| Where state runs | in-cluster (simple, disposable) | outside the cluster (survivable) |
| Secret backend | file/template provider | external store + operator |
| Storage backing | node disk | provisioned block/file storage |
| Hostnames | `*.localhost` | a real domain and/or an overlay network |

### Should be absent in dev, and explicitly so

Backups, point-in-time recovery, off-site copies, the registry cache, alerting
and HA are **operational** concerns. A developer does not exercise them, and
requiring them on a laptop would make the platform hostile to start with. But
their absence should be *stated* rather than discovered — a developer should
never assume a laptop deployment is protecting their data.

### ⚠️ Parity depends on the developer's Rancher Desktop version

UIS ingress manifests use Traefik **v3** syntax (`HostRegexp` with named
matchers, `traefik.io` CRDs). Which Traefik a developer gets is decided entirely
by their Rancher Desktop version, because k3s bundles it:

| Rancher Desktop / k3s | Traefik chart | Traefik | Result |
|---|---|---|---|
| current (k3s v1.36) | 40.1.3 | **3.7.x** | ✅ matches production |
| old (k3s v1.25) | 25.0.2 | **2.10.5** | ❌ every route 404s |

On the older build the legacy `traefik.containo.us` CRDs are present and the v3
syntax silently fails to match — **services 404 while the playbooks report
success and exit 0**. Parity fails in the worst direction: development is the
broken one, and nothing says so.

**UIS does not check this.** There is no minimum Rancher Desktop / k3s version
declared or verified anywhere, so a developer on a stale install gets a
deployment that reports healthy and does not work. A preflight check — assert
Traefik major ≥3, or assert the k3s version — would turn a confusing afternoon
into one clear error message.

Any change made for production should be checked against this contract. If it
forces a developer to configure something differently, the change is in the wrong
layer.

## Components beside the cluster

Following from #1 and #7, a production UIS install has a recurring set of
components that are *not* Kubernetes services:

| Component | Why it is outside | Notes |
|---|---|---|
| **Database** | survivability, bootstrap, multi-cluster | in-cluster services still reach it by its usual name |
| **Object storage** | reachable by workers outside the cluster | avoids ingress for internal consumers |
| **Secret store** | bootstrap + recovery circularity | see [secrets](./secrets.md) |
| **Image/registry cache** | the cluster cannot pull the images that start the cluster | also fixes registry rate limits |
| **Management plane** | must work when the cluster does not | holds kubeconfigs for all targets |
| **Scheduler for infrastructure jobs** | a backup job must not depend on what it backs up | cluster CronJobs die with the cluster |

### They also need a network — and it should be the most local one available

Once state lives beside the cluster, something has to say *where* it is. That
address is easy to get wrong in a way that only hurts later.

On the reference deployment every guest was on DHCP, so there was no stable
address to configure — and the overlay network (Tailscale) was used instead,
because its addresses do not move. It worked, and it was the wrong layer: the
database and the cluster were on the **same virtualisation host**, so every
query was being encrypted and pushed through a WireGuard tunnel to reach a
neighbour on the same virtual switch.

Three problems, in increasing order of importance:

- **Cost** — 0.733 ms vs 0.153 ms per round trip, plus encryption overhead and a
  reduced MTU, on traffic that never needed to leave the machine.
- **A failure mode that did not need to exist** — the overlay path was observed
  going completely dead for several minutes and then recovering unattended. On
  the cluster→database path that is a simultaneous outage of every service.
- **It breaks [decision 7](#7-anything-on-the-startup-path-must-be-local)** — an
  overlay network depends on a hosted coordination service. A database is on the
  startup path, so it must not.

**The rule:** *connect components by the most local path that works.* Same host
→ a host-only bridge. Same LAN → static LAN addresses. Different sites → then,
and only then, an overlay. Keep the overlay for reaching the platform from
outside, which is what it is good at.

The trap to recognise: **if you are using an overlay network for its stable
addressing rather than for its reach, the actual missing piece is addressing.**
Fix that instead — static addresses, a host-only network, or internal DNS.

---

## Production readiness checklist

| ✔ | Item | Why |
|---|---|---|
| ☐ | Secrets generated, no shipped defaults | defaults are published in this repo |
| ☐ | Secret store outside the cluster | bootstrap + recovery |
| ☐ | Database outside the cluster, with PITR | dumps alone mean up to 24 h loss |
| ☐ | **Restore tested**, not just backup run | see #4 |
| ☐ | Off-site copy of backups | fire/theft/flood |
| ☐ | Backup-freshness alert | silent failure is the norm |
| ☐ | Alert rules exist and route somewhere | monitoring ≠ alerting |
| ☐ | Log collection agent installed | Loki is empty without one |
| ☐ | Targets outside the cluster monitored | host, DB, storage, backups |
| ☐ | Registry cache, warmed | restart during an outage |
| ☐ | Public vs private decided per service | ingress exposes by default |
| ☐ | Management plane always-on | not a laptop |
| ☐ | Hosts agree on a timezone | cross-host job ordering |
| ☐ | Jobs avoid the DST transition hour | a timer can be skipped entirely |

---

## Platform guides

**Two different things are tracked below, and it matters which one you need:**

- **Platform support** — can UIS *provision a cluster* there? (`uis platform up`,
  host templates, cloud-init)
- **Production guide** — is there a documented path to the decisions above:
  state outside the cluster, secrets, backups, alerting, offline capability?

They are independent. A platform can be well supported for development and still
have no production story — and vice versa.

| Platform | Platform support | Production guide |
|---|---|---|
| **Proxmox VE** | ❌ no host template — the cluster is built by hand | ✅ [Available](./proxmox.md) — the reference deployment |
| **Azure AKS** | ✅ OpenTofu + scripts + manifests; `uis platform up azure-aks` | ⏳ not yet |
| **Azure (MicroK8s VM)** | ✅ documented host template | ⏳ not yet |
| **Google Cloud** | 🟡 cloud-init template only — no platform implementation | ⏳ not yet |
| **Oracle Cloud (OCI)** | 🟡 cloud-init template only — no platform implementation | ⏳ not yet |
| **AWS** | ❌ nothing yet | ⏳ not yet |
| Rancher Desktop | ✅ the development default | n/a — development, not production |

Note the inversion: **Proxmox has a production guide but no provisioning
support**, while **Azure has provisioning support but no production guide**.
Closing either gap is useful work; they are separate pieces.

### What a new production guide has to cover

The principles above are platform-independent — a guide only supplies the
mechanics. Concretely, for each of the [components beside the
cluster](#components-beside-the-cluster), say which primitive provides it:

| Component | Proxmox (reference) | On a cloud, typically |
|---|---|---|
| Database | container + ZFS dataset | managed SQL (RDS / Cloud SQL / Azure Database) |
| Object storage | container + ZFS dataset | the provider's object store |
| Secret store | self-hosted vault | the provider's key vault — **but see the caveat below** |
| Image cache | pull-through registry container | the provider's registry, with caching/replication |
| Management plane | small always-on container | a small VM, or CI |
| Infrastructure scheduler | host timers | whatever runs when the cluster does not |

⚠️ **A managed key vault is only appropriate if you accept a hard dependency on
that provider for cluster startup.** If the deployment must survive provider
outages, the store has to be local — see
[decision 7](#7-anything-on-the-startup-path-must-be-local). This is the one
place where the cloud-native answer and the resilience answer disagree, and it
should be a deliberate choice per deployment.
