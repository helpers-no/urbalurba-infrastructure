---
title: INVESTIGATE — replacing MinIO with Garage
sidebar_label: INVESTIGATE — MinIO to Garage
---

# Investigate: should UIS replace MinIO with Garage as its object store?

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Decided by Terje, 2026-10-01. Building.

> *"i think that we now need to do the minio replacement"* — Terje, same day as the withdrawal finding below.

**The `garage` UIS service is written** (`service-garage.sh`, `047-setup-garage.yml`, `047-remove-garage.yml`, `047-test-garage.yml`, `047-garage-config.yaml`, `048-garage-ingressroute.yaml`). 🔴 **Not yet verified on a cluster.** See `/docs/services/storage/garage` for the full design and what is honestly still open - in particular, Garage's `--default-bucket` credential is scoped to **one bucket**, not a root/admin key the way MinIO's was, so a second bucket consumer (the Loki/Tempo migration off MinIO) is a separate, not-yet-filed piece of work, not something this first deliverable includes.

**What stays open below** is the context for *why*, kept for whoever tests or extends this, not because the swap itself is still a question.

🔴 **2026-10-01, same day as filing: `ops` reports, and I have independently confirmed, that MinIO's images are no longer obtainable from any public source — not Docker Hub, not quay.io, not the binary.** This does not decide MinIO vs Garage. It does mean `./uis deploy minio` **cannot succeed today on a cluster with no cached MinIO image**, regardless of which replacement (if any) is chosen. See the new section below; everything after it is unchanged from the original filing.

🔵 Filed 2026-10-01 on Terje's instruction: *add the swap from MinIO to Garage to the backlog, but an investigation must be created first.*

**What triggered it.** Terje's stated motive, as relayed by `ops` (`urb-agents#1795`): *"ask tor-agent on the bus if uis has decided garage **in order to stay sovereign**."* `ops` is about to write the object-store role for the rebuilt three-node lab and did not want to build the wrong one.

**No decision exists, and none was ever written down.** The git tree on `main` (`f505870`) has 0 files mentioning Garage, against 65 for MinIO as the positive control. The bus, my memory notes, handovers and session transcripts have nothing before 2026-10-01 either. `ops` was told to write a deliberately thin MinIO role in the meantime, so the lab does not wait on this.

⚠️ **How to read the sources below.** Each fact is labelled: **measured** (I ran it, today), **reported** (someone else measured it and I did not repeat it), **docs** (fetched from the project's own site today), **secondary** (a search result, not read in full), or **unverified** (recalled, not confirmed).

## 🔴 MinIO's images are gone, not just stale — measured independently, 2026-10-01

`ops` reported this in `urb-agents#1801`, following up same-day on `#1795`. **I repeated every check myself, with my own controls, before writing this down.**

**The exact reference UIS's own chart would pull** — not `latest`, the pinned tag from `manifests/045-minio-config.yaml`, read out of the fetched chart's `values.yaml` (`image.repository` defaults to `quay.io/minio/minio` since UIS overrides neither):

```
quay.io/minio/minio:RELEASE.2024-12-18T13-15-44Z   -> 401 Unauthorized (manifest request, with a valid anon token)
quay.io/minio/mc:RELEASE.2024-11-21T17-21-54Z      -> 401 Unauthorized (same)
```

🔴 **The `mc` image matters as much as the server image.** The chart's `post-job.yaml` runs `mc` in **five** separate Jobs/containers to create buckets and policies after the server starts. A cluster that somehow had the server image cached would still fail there.

**Broader checks, each with a control run the same minute:**

| target | result | control, same minute |
|---|---|---|
| `dl.min.io/server/minio/release/linux-amd64/minio` | **410 Gone** | `registry-1.docker.io` manifest for `library/alpine:3.20` → 200 |
| `docker.io/minio/minio:latest` (manifest, valid token) | **401** | `quay.io/prometheus/node-exporter:latest` (manifest, valid token) → 200 |
| `quay.io/minio/minio:latest` (manifest, valid token) | **401** | same control → 200 |
| `quay.io/minio/mc:latest` | **401** | — |
| GitHub `minio/minio` latest release (`RELEASE.2025-10-15T17-29-55Z`) | tag exists, **0 release assets** | — |

**So this is not account-gating returning a clean "pay for this."** A `401`/`unauthorized` with no path to a credential that resolves it, a `410 Gone` on the binary, and a tagged GitHub release with nothing attached, together say the artifact is **withdrawn**, not merely licensed differently.

**On ops's second question — does a licence or account restore access:** `min.io/download` offers exactly two things, both under the name **AIStor**, not MinIO: *"AIStor Free"* and a 60-day *"AIStor Enterprise Trial"*, both gated behind requesting a licence key. ⚠️ **I did not request one**, so I cannot say whether AIStor Free is a drop-in replacement image with the same S3 API, or something else entirely. What I can say is that **the open-source `minio/minio` artifact UIS's chart names has no path back**, under any name I could find, free or paid.

🔵 **What this changes for the investigation below.** Section "Options" still holds — A/B/C/D are all still on the table — but **Option A ("stay on MinIO, fix the pin") is no longer available as written**, because pinning a specific tag of an image that cannot be pulled fixes nothing. A revived Option A would mean building the MinIO *server* from source (it is still source-available, AGPLv3, per the README) and publishing UIS's own image — which is a different, larger undertaking than "add `--version`".

**What is NOT yet known:** whether `./uis deploy minio` has actually been run against a cluster with a cold image cache since this happened. ⚠️ I have no cluster and no Docker on this host, so I verified the registry side — which is the determinative fact, since kubelet, containerd and a developer's own `docker pull` all hit the same registry API I just hit — but **nobody has watched the Helm install itself fail**. `ops` asked the same question and has not run it either. This is `imac`'s to confirm.

## What UIS actually asks of MinIO — measured on `main`

| UIS depends on… | Evidence | Matters for a swap because |
|---|---|---|
| **Plain S3 only** — make bucket, put, get, remove, remove bucket | `045-test-minio.yml` runs `mc alias set / mb / cp / cat / rm / rb`; no `mc admin`, `anonymous`, `policy`, `version`, `ilm`, `tag`, `retention` or `encrypt` anywhere in the MinIO playbooks, manifests or service definition | the S3 surface UIS itself uses is small |
| **A web console on port 9001**, with its own Traefik route (`minio.<domain>`) | `045-setup-minio.yml` task 16; **`045-test-minio.yml` test C treats the console as CRITICAL**; `minio.md` lists it as a key capability | 🔴 Garage documents no console. This is the one UIS feature with no direct counterpart |
| **Root credentials from `urbalurba-secrets`**, derived from `DEFAULT_DATABASE_PASSWORD` | `00-common-values.env.template:207`; `045-setup-minio.yml` tasks read `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` | the object store is wired into the UIS secret model, not deployed beside it |
| **No other UIS service depends on it** | `SCRIPT_REQUIRES` is empty on every service in `provision-host/uis/services` | blast radius inside UIS is the service itself |
| **UIS's own Loki does not use it** | `manifests/032-loki-config.yaml` sets `object_store: filesystem` | the live Loki-on-MinIO consumer below is lab configuration, not a UIS consumer |

## 🔴 Found while looking: UIS's MinIO is frozen at December 2024, whatever happens next

**Measured today** against `https://charts.min.io/index.yaml`:

- the index was **`generated: 2025-01-02`** and has not been regenerated since
- the newest entry is chart **5.4.0**, `appVersion: RELEASE.2024-12-18T13-15-44Z`, created 2025-01-02

**And UIS installs it unpinned.** `045-setup-minio.yml` task 11 runs `helm upgrade --install minio minio/minio` with **no `--version`**, and `045-minio-config.yaml` leaves `image.tag` empty — *"Empty tag uses the chart's appVersion"*. So a fresh `uis deploy minio` installs whatever that index says, which is a release built on 2024-12-18 — about 21 months before this was filed.

⚠️ `ops` reported the lab's MinIO runs `RELEASE.2025-09-07T16-13-09Z`, so the lab is **not** on the chart's image: it was installed another way. The two have already diverged.

🔵 This is independent of Garage. **Even if MinIO stays, UIS's deploy path is not tracking a maintained artifact**, and that is worth knowing before anyone weighs the swap.

## Why MinIO is being questioned at all

- **docs** — the MinIO repository's README (fetched today) opens with **"THIS REPOSITORY IS NO LONGER MAINTAINED."**, says the community edition is *"now distributed as source code only. We will no longer provide pre-compiled binary releases"*, and points users to **AIStor Free** and **AIStor Enterprise**. Licence: AGPLv3.
- **secondary** — search results (not read in full) report the admin console was stripped from the community edition in May 2025, and that MinIO announced "maintenance mode" on 2025-12-03: no new features, issues and PRs no longer reviewed, security fixes "as appropriate".

## What Garage is — docs, fetched today from garagehq.deuxfleurs.fr

| | |
|---|---|
| maintainer | Deuxfleurs, a French hosting cooperative |
| current stable | **v2.3.0**, as the quick-start names it |
| shape | one dependency-free binary; designed for geo-distribution across sites, with 3-zone replication as the described design |
| minimum hardware | 1 GB RAM, 16 GB storage; x86_64, ARMv7 or ARMv8 |
| ports (single node) | S3 API `3900`, RPC `3901`, admin API `3903` |
| administration | the `garage` CLI; **the quick-start mentions no web console** |
| on Kubernetes | a Helm chart at `script/helm` **in the repository**, creating a StatefulSet; *"cluster layout must be configured manually"* afterwards |
| single node | `replication_factor = 1`, `db_engine = "sqlite"`; the guide warns *"this kind of deployment should not be used in production, as it provides no redundancy for your data"* |

### 🔴 The S3 gaps, quoted from Garage's own compatibility page

**Fully implemented:** Signature v4, path-style **and** vhost-style access, presigned URLs, SSE-C, all bucket and object CRUD, `ListObjectsV2`, `CopyObject`, `DeleteObjects`, and **all seven multipart endpoints**.

**Partial:** lifecycle supports only `AbortIncompleteMultipartUpload` and `Expiration`; `GetBucketVersioning` is a stub that *"always returns 'versioning not enabled'"*.

**Not implemented:** all ACL and bucket-policy endpoints, versioning, object lock, server-side encryption other than SSE-C, all tagging, **replication**, notifications, and the rest of the long tail.

🔵 Everything UIS itself uses is on the implemented list. Everything UIS does not use is, for the most part, the not-implemented list — which is why the first-order answer looks favourable. **The risk is in consumers UIS does not control.**

## Gap analysis, as far as the evidence reaches

| Concern | MinIO today | Garage | State |
|---|---|---|---|
| bucket / object / multipart / presigned | ✅ | ✅ documented | docs |
| UIS's `mc` round-trip test works unchanged | ✅ | ? | **unverified** — `mc` is an S3 client, but nobody has run it against Garage here |
| a web console | ✅ (stripped to a viewer in the community build, per secondary) | ❌ none documented | 🔴 decision needed: drop it, replace it, or run a third-party UI. ⚠️ A community web UI for Garage may exist; **not checked** |
| root credentials from `urbalurba-secrets` | ✅ `rootUser` / `rootPassword` | ? access keys come from `garage key create` | **unverified** whether a chosen key can be imported; if not, the secret model needs a different shape |
| works with no manual step | ✅ | 🔴 the layout must be assigned **and applied** before use, even on one node (`garage layout assign -z dc1 -c 1G <node>` then `garage layout apply --version 1`) | docs. UIS's premise is that a deploy is one command ([Principle 0](../../../contributors/rules/kubernetes-deployment.md)), so this becomes automation that must be idempotent |
| chart source | `charts.min.io`, unpinned, stale | a chart **in the git repository**, not a Helm repo | docs. Pinning and provenance work differently; UIS pins images by digest elsewhere |
| image provenance | quay-hosted, last chart image Dec 2024 | ? | **unverified** which image and registry Garage publishes |
| consumers' needs: bucket policies, versioning, tagging, lifecycle beyond expiry | whatever they use | ❌ unsupported | **unknown** — see below |
| cross-site replication | MinIO site replication | 🔴 `ReplicationConfiguration` is not implemented, though the *system* replicates internally across zones | not the same feature; which one the multi-site vision needs is an open question |
| licence | AGPLv3 (docs) | **unverified** — no page I could fetch states it; I believe AGPLv3 and have **not** confirmed it | confirm before it appears in any decision record |

## Who actually uses the object store — reported by `ops`, 2026-10-01, not re-measured here

| bucket | files | state |
|---|---|---|
| `loki` | 1419, newest 2026-10-01 | live — Loki's chunk store, 84 MB |
| `tempo` | 1 | a marker object, nothing since |
| `urbalurba-images` | 0 | empty; **nothing on `main` mentions that name**, so UIS has never been the writer |
| `pgbackrest` | 0 | empty; pgBackRest uses a posix repo because it needs TLS for S3 repos |

🔵 One live consumer, and it holds logs. **A migration is probably "start empty" for the lab**, and the question that matters is what *UIS users* have put in theirs — which no one has measured.

## What "sovereign" has to mean for this to be decidable

Terje's word, and the investigation cannot answer it for him. The criteria it implies, to be confirmed:

- [ ] no single vendor can change the terms of the software UIS depends on
- [ ] self-hostable with no account, no licence key and no phone-home
- [ ] jurisdiction or governance of the maintainer matters, or does not
- [ ] ability to **build and run it from source** if upstream stops

⚠️ On the last one MinIO now scores *worse* than before — source-only, unmaintained — while Garage is a cooperative-maintained single binary. That is an argument, not a measurement of either project's long-term health.

## Options

| | |
|---|---|
| **A. Stay on MinIO, but fix the deploy** | pin chart and image, decide whether to build from source; keeps the console |
| **B. Garage** | the proposal; needs the console decision and layout automation |
| **C. Something else** | the search results name other S3 servers. **None were read**, so none are evaluated here |
| **D. Make the object store pluggable** | UIS's S3 surface is small enough that a service-level contract may be cheaper than choosing; but it is more design than either A or B |

## What has to be measured before anyone decides

All of this needs a cluster, which the maintainer's host does not have; `imac` is the place.

- [ ] 1.1 Run Garage single-node in a throwaway namespace; **time the manual layout steps** and write them as an idempotent deploy task
- [ ] 1.2 Run the `045-test-minio.yml` round-trip (`mc mb / cp / cat / rm / rb`) against Garage unchanged, and record what differs
- [ ] 1.3 Whether a chosen access key and secret can be **imported**, so `urbalurba-secrets` stays the source of truth
- [ ] 1.4 Point Loki and Tempo at Garage and confirm chunk write, read and retention behave; **both use lifecycle-adjacent features Garage only partly implements**
- [ ] 1.5 Restart and re-deploy: does the layout survive a pod restart and `undeploy` (UIS keeps the PVC by design)? A layout that vanishes is a silent data-loss bug
- [ ] 1.6 Resource use on the 10 GB VM `imac` has, next to everything already running
- [ ] 1.7 Which image and registry Garage publishes, whether it can be pinned by digest, and the licence, **read from the source repository**
- [ ] 1.8 🔴 What a UIS user's buckets contain, and whether any application relies on a policy, versioning or tagging. This is the finding that could kill option B on its own
- [ ] 1.9 Re-measure `charts.min.io` and decide the unpinned-deploy question **regardless of the outcome**

## What each outcome produces

- **A** → a plan that pins `minio/minio` and its image, and records the build-from-source decision
- **B** → plans for a `garage` service, the console replacement, the credential model, and a migration; then a deprecation path for `minio`
- **D** → a design document before any plan

## Not in scope

No code, no build, and no change to the lab. `ops` writes its thin MinIO role in parallel, shaped so that a later swap is *a different `ExecStart` and the same bucket list*.

## Related

- `urb-agents#1795` — the question that opened this
- [INVESTIGATE-system-external-or-in-cluster-services](./INVESTIGATE-system-external-or-in-cluster-services.md) — MinIO as the second proof of the external-proxy convention
- [INVESTIGATE-system-backup-and-scheduling](./INVESTIGATE-system-backup-and-scheduling.md) — why the object store is not in the database backup path
