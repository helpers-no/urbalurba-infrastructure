---
title: Proxmox VE
sidebar_label: Proxmox VE
sidebar_position: 2
---

# Production UIS on Proxmox VE

The reference on-premises production deployment: a single Proxmox host running
one Kubernetes cluster plus the [components beside the cluster](./index.md#components-beside-the-cluster).

Read [Production overview](./index.md) first — this page is only the mechanics.

Everything here was built and verified on a real deployment. Where something bit
us, it is called out as a **⚠️ gotcha** rather than left for you to rediscover.

---

## Topology

| Guest | Type | Purpose |
|---|---|---|
| *(host)* | Proxmox VE | hypervisor, ZFS pool, guest backups |
| `k8s` | VM | the cluster (k3s) |
| `pg` | LXC | PostgreSQL — outside the cluster |
| `minio` | LXC | object storage — outside the cluster |
| `bao` | LXC | secret store — outside the cluster |
| `registry` | LXC | pull-through image cache — outside the cluster |
| `ops` | LXC | management plane (provision-host + kubeconfigs) |
| `nas` | LXC | optional: SMB/NFS file shares |

Containers rather than VMs for the supporting services: lower overhead, and they
boot in seconds. The cluster itself is a VM — k3s in an LXC is possible but
fights you over kernel modules and cgroups.

## Storage tiering

With two disks, split them by *purpose*, not size:

| Tier | Disk | Holds | Snapshots? |
|---|---|---|---|
| **systems** | fastest/healthiest | guest rootfs, VM system disks, container images | no — rebuildable |
| **data** | capacity | database, object store, secrets, file shares, backups | yes |

Put the data tier on **ZFS** — snapshots, checksums and compression are what make
the backup story work. Tune per dataset: `recordsize=16K` for PostgreSQL (matches
its page size), `1M` for object/blob storage and backup archives.

⚠️ **Kubernetes system disks belong on the systems tier.** Image churn on the data
disk buys nothing — as a zvol it does not get dataset-level snapshots anyway.

---

## Build sequence

### 1. Host preparation

Update Proxmox, create the ZFS pool, and cap the ARC if guests will use most of
the RAM (`options zfs zfs_arc_max=…` in `/etc/modprobe.d/zfs.conf`) — otherwise
ARC and your guests compete.

⚠️ Check the bootloader matches the boot mode. A host booting via EFI with only
the BIOS GRUB package installed will boot today but silently stop receiving
bootloader updates.

### 2. Cluster VM

An Ubuntu LTS cloud image plus cloud-init is the fastest path. Then k3s:

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --write-kubeconfig-mode 644" sh -
```

k3s ships Traefik v3, matching the UIS manifests. It is also what Rancher Desktop
runs, so development and production behave the same.

⚠️ **Cloud images take their DHCP lease before cloud-init applies the hostname**,
so DNS registers the host as `ubuntu`. Set the hostname before networking, or
force a lease renewal afterwards.

### 3. Components beside the cluster

Each in its own container, each with its **data on a tuned ZFS dataset**:

- **PostgreSQL** — install from PGDG for a current version with `pgvector`/`PostGIS`.
  On ZFS, set `full_page_writes = off`; copy-on-write makes torn pages impossible,
  so PostgreSQL's own full-page writes are redundant. Keep `pg_wal` in the *same*
  dataset as the data so a snapshot is atomic and crash-consistent.
- **Object storage** — MinIO as a systemd service, data on a `recordsize=1M` dataset.
- **Secret store** — see [secrets](./secrets).
- **Registry cache** — see step 7.

Expose them on the overlay network so machines outside the cluster (developer
laptops, workers at other sites) can reach them directly.

#### ⚠️ Making UIS accept an external database

UIS currently assumes PostgreSQL and MinIO run *in* the cluster in two places:
its dependency check looks for a **Running pod** with a specific label, and some
playbooks `kubectl exec` **into that pod** to run `psql`. An external database
satisfies neither.

Until UIS supports an external mode, bridge it with a small in-cluster
Deployment carrying the expected label:

- **container 1** — a `postgres` image running `sleep infinity`. It must be
  **first**, because that is where `kubectl exec` lands, and it needs `bash` +
  `psql`. Set `PGHOST` on it so bare `psql` uses TCP rather than a Unix socket.
- **container 2** — `socat` forwarding the pod's `:5432` to the real host.

Plus a normal ClusterIP Service selecting it. UIS is then satisfied, playbooks
work unchanged, and the database stays outside Kubernetes. The same pattern works
for MinIO (an `mc` container first, socat for `:9000`/`:9001`).

**Do not `uis deploy postgresql` afterwards** — it would replace the bridge.

### 4. Management plane

Install Docker in the `ops` container and run the provision-host there, holding
kubeconfigs for every target.

⚠️ **Never run `./uis` with `sudo`** — it mounts *root's* `~/.kube` (so the wrong
kubeconfig) and leaves `.uis.extend` / `.uis.secrets` owned by root.

### 5. Storage classes — request a disk, get a disk

`proxmox-csi-plugin` lets a PVC create a real Proxmox disk and hot-attach it to
the cluster VM, so services get storage on demand across both tiers:

| Class | Backed by | For |
|---|---|---|
| `fast` | systems-tier storage | latency-sensitive workloads, monitoring TSDBs |
| `standard` *(default)* | data-tier ZFS | general persistent data |
| `shared` | NFS export from the host | `ReadWriteMany` |
| `local-path` | node disk | scratch only — not snapshotted |

**Make the backed-up class the default.** UIS service manifests deliberately omit
`storageClassName` so they inherit the cluster default — one lever then governs
storage for the whole platform.

⚠️ The node needs `providerID: proxmox://<region>/<vmid>`. k3s sets `k3s://<node>`
and **providerID is immutable** — set `kubelet-arg: provider-id=…`, restart k3s,
delete the node object, restart again so it re-registers, then re-apply the
topology labels.

⚠️ **Prometheus cannot run on NFS** (it needs mmap and POSIX locks) — give it a
block-backed class.

### 6. Secrets

See the [secrets guide](./secrets). The short version: a store outside the
cluster, External Secrets Operator inside it, and Kubernetes auth so nothing
static is stored in the cluster to bootstrap secret access.

### 7. Registry cache

Without it the cluster cannot restart when upstream registries are unreachable.
See the [registry cache guide](./registry-cache).

### 8. Ingress

Two complementary paths:

- **Private** — an overlay-network ingress for admin UIs. No DNS, no public
  exposure, no certificates to manage.
- **Public** — a tunnel to your CDN/edge for the few services that should be
  reachable, with authentication in front.

⚠️ Some overlay "expose" helpers publish to the **public internet** and **bypass
the reverse proxy**, so forward-auth middleware does not apply. Read what the
command actually does before using it for an admin UI.

### 9. Backups — four layers

| Layer | Protects against | Frequency |
|---|---|---|
| ZFS snapshots | deletion, bad writes | every 15 min |
| Database PITR (WAL archiving) | data loss between backups | continuous, RPO ≈ 5 min |
| Guest backups (`vzdump`) | losing a whole VM/container | nightly, snapshot mode |
| Off-box copy (restic) | losing the host | nightly |

⚠️ **Order matters, and hosts must agree on a timezone.** A container on UTC and
a host on local time will run "02:30" and "03:30" jobs three hours apart — with
the dump landing *after* the backup that was supposed to capture it, so every
offsite copy is a day stale while both jobs report success.

⚠️ **Avoid scheduling in the DST transition hour** (02:00–03:00 in Europe). At
spring-forward that hour does not exist and the job is silently skipped.

### 10. Verify the restores

Not optional — see [production overview #4](./index.md).

- Restore a database dump into a scratch database.
- Restore a file from the off-box repo and compare it byte-for-byte with the live one.
- Restore a guest to a spare VMID and boot it.
  ⚠️ A *privileged* container must be restored with `--unprivileged 0`, or `tar`
  fails with a uid-mapping error.
- Do a point-in-time restore into an alternate directory and start a temporary
  instance on a spare port — this validates PITR without touching production.
  ⚠️ On Debian, `postgresql.conf` lives in `/etc`, **not** the data directory, so a
  restored data directory needs a minimal config supplied by hand.

### 11. Observability

Install the stack, then do the part that makes it useful: a log-collection agent,
alert rules, and scrape targets for the components outside the cluster —
including backup freshness. See [production overview #5](./index.md).

---

## What you end up with

- One Kubernetes cluster running the UIS service catalogue.
- Database, object storage, secrets and image cache **outside** it — each
  independently restartable, each backed up.
- Storage on demand across two performance tiers.
- Private access to admin UIs, public access only where chosen.
- Four backup layers, **restore-tested**, with point-in-time recovery for the
  database.
- A management plane that does not depend on anyone's laptop.
