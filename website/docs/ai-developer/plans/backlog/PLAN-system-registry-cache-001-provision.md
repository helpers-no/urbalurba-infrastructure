# Plan: Registry cache — provision the cache itself (zot, not registry:2)

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: Provision a single zot instance as UIS's pull-through registry cache — the
host/platform-layer component [INVESTIGATE-system-registry-cache.md](./INVESTIGATE-system-registry-cache.md)
(F1) and [production/registry-cache.md](../../production/registry-cache.md) both call for but UIS has
never actually built.

**Investigation**: [INVESTIGATE-system-registry-cache.md](./INVESTIGATE-system-registry-cache.md)
**Related**: [INVESTIGATE-system-remote-deployment-targets.md](./INVESTIGATE-system-remote-deployment-targets.md)
— this cache is not a cluster service (F1), so it needs a host/target to run on; that investigation
is where "a non-cluster component in the UIS model" gets decided.
**Blocks**: PLAN-system-registry-cache-002-cluster-wiring.md (render `registries.yaml` once this
exists), PLAN-system-registry-cache-003-warm-verify.md (the real outage acceptance test)
**Last Updated**: 2026-10-05

---

## Problem Summary

UIS has no registry mirror anywhere:

```bash
grep -rl 'registries.yaml\|registry-mirror\|pull-through' . # → no matches outside this plan's own docs
```

Both existing docs describe a reference implementation built on the maintainer's own Proxmox lab,
using four `registry:2` containers (one per upstream — `registry:2` only proxies a single upstream
per instance). **That reference implementation has since been swapped to zot** in a separate,
already-built-and-validated platform (`platforms/proxmox`, not part of UIS proper) — this plan is
about bringing that same engine choice into UIS, not the older four-container design the backlog doc
still shows.

**Why zot, not registry:2 (decided 2026-10-05, Terje):** the real requirement is "cache every image
UIS ever deploys, including from upstreams nobody's picked yet." `registry:2` only gets there by
hand-adding a new container + port + GC unit per upstream, forever. zot takes any number of upstreams
in **one instance** — a new upstream becomes a config list entry, not a new service.

**Why not Harbor:** evaluated and ruled out. Harbor needs its own Postgres + Redis, which is exactly
the kind of dependency a bootstrap-critical cache cannot carry (F1's whole point: the cache has to
come up with nothing but itself).

---

## Reference implementation — already built and validated, port from here

`platforms/proxmox/ansible/roles/registry/` is a working zot role, validated for real against a live
3-node Proxmox lab on 2026-10-05 (destroyed and rebuilt the guest, confirmed all 4 upstreams actually
cache — not just that the daemon answers — and confirmed it runs as a non-root `zot` user at ~115 MB
RSS). This plan is about **adapting that role's approach to wherever UIS decides a non-cluster
component lives** (see the remote-deployment-targets investigation), not re-deriving it from scratch.

What to carry over, concretely:

- **Config schema** (`templates/zot-config.json.j2`): one `extensions.sync.registries[]` entry per
  upstream (`dockerhub`→`/docker`, `k8s`→`registry.k8s.io`→`/k8s`, `ghcr`→`/ghcr`, `quay`→`/quay`),
  each `onDemand: true`. ⚠️ Docker Hub **must** stay `onDemand`-only with no `pollInterval` — it
  rate-limits pulls and doesn't support catalog listing, so polling it is actively harmful (zot's own
  docs, not guessed).
- **Binary, not an image**: zot ships a static binary (`zot-linux-amd64`), so there is no Docker
  dependency at all — a whole category of bootstrap circularity this cache used to need to survive
  (the old `registry:2` mirrors were themselves pulled from docker.io). Pin by sha256 checksum against
  the real release asset, same discipline as every other pinned artifact in this repo. Verified
  checksum for v2.1.21 at the time of writing:
  `sha256:8751cc0daf739634835a3bd8206e3094c84d552e2c462e4a4baf80f40dd92685` (re-verify against
  `https://github.com/project-zot/zot/releases/<version>/checksums.sha256.txt` before using — don't
  trust this copy blind as the version ages).
- **Seed-on-first-boot**: keep a copy of the verified binary on persistent storage, install from the
  seed when present, download (verify, then refresh the seed) only when it isn't. The exact pattern
  `platforms/proxmox/ansible/roles/registry/tasks/main.yml` uses for the binary — same shape this
  repo already uses for Docker images elsewhere (`garage`, `registry`'s own previous version), just
  one file instead of `docker save`/`load`.
- **Built-in GC**: `storage.gc`/`gcDelay`/`gcInterval` in zot's own config. No hand-rolled GC
  timer needed — the old `registry:2` design had to build one; zot ships it.
- **Verification that proves the documented acceptance criteria, not just that the daemon answers**:
  `GET /v2/` returning 200 proves nothing about caching — a dead mirror looks identical to a working
  one until the one day it matters (`production/registry-cache.md`'s whole point). Warm one small,
  verified-reachable, public image **through each upstream's own mirror path**
  (`GET /v2/<destination>/<path>/manifests/<tag>`, note the required `/v2/` prefix — a bug I caught
  in my own first draft of this exact task, worth a second look when porting), then confirm it
  actually landed via `GET /v2/_catalog` — never trust the warm request's exit code alone. Known-good
  test images verified reachable on 2026-10-05, likely to still work but re-verify before relying on
  them: `library/alpine:latest` (Docker Hub), `pause:3.9` (`registry.k8s.io`),
  `stefanprodan/podinfo:latest` (ghcr.io), `quay/busybox:latest` (quay.io).

What's genuinely different for UIS and needs a real decision, not a copy-paste:

- **Where does it run?** `platforms/proxmox` runs it as a systemd unit on a dedicated Proxmox LXC
  guest. UIS has no equivalent "non-cluster host component" concept yet — that's exactly
  [INVESTIGATE-system-remote-deployment-targets.md](./INVESTIGATE-system-remote-deployment-targets.md)'s
  open question. Resolve that first, or decide it as part of this plan if it's still unresolved.
- **One cache for how many clusters?** The investigation flags "one cache for many clusters" as an
  open question (dev laptops, production, CI) — resolve scope before implementing, since it changes
  whether this is per-developer or shared infrastructure.

---

## Phase 1: Decide where it runs and provision it

### Tasks

- [ ] 1.1 Resolve (or explicitly scope-limit) the "non-cluster component" placement question from
      `INVESTIGATE-system-remote-deployment-targets.md`
- [ ] 1.2 Port the config schema, binary pinning, seed/bootstrap pattern, and systemd unit from
      `platforms/proxmox/ansible/roles/registry/` into wherever that placement decision lands
- [ ] 1.3 Port the warm-through-mirror-path + `/v2/_catalog` verification (not a bare `GET /v2/`
      check) — this is the one place a copy-paste of the *old* registry:2-era verification would
      quietly undershoot the documented acceptance bar
- [ ] 1.4 Re-verify the binary checksum against the current zot release before pinning it — do not
      reuse the checksum in this plan without checking it still matches the version you pin

### Validation

```bash
curl -s http://<cache-host>:5000/v2/_catalog
```
Each configured upstream's warmed test image appears. User confirms the cache answers and the
catalog is non-empty for all configured upstreams.

---

## Acceptance Criteria

- [ ] One zot instance, not four `registry:2` containers, fronting every upstream UIS pulls from
- [ ] Binary installed from a pinned, verified checksum; reinstall works with no internet once a
      seed copy exists
- [ ] GC configured (zot's built-in `gc`/`gcDelay`/`gcInterval`), not hand-rolled
- [ ] Verification proves an actual cache hit per upstream via `/v2/_catalog`, not merely that the
      daemon answers
- [ ] Documentation updated: `production/registry-cache.md` still describes `registry:2` (four
      containers, one upstream each) — update it to describe the zot-based single instance before
      calling this plan done, or a reader will build the wrong thing from it

---

## Files to Reference (not modify directly — this UIS repo's own target location is still open)

- `platforms/proxmox/ansible/roles/registry/` (this repo, separate platform) — the validated
  reference implementation: `defaults/main.yml`, `tasks/main.yml`, `templates/zot-config.json.j2`,
  `templates/zot.service.j2`
- `website/docs/production/registry-cache.md` — needs updating once this ships (currently still
  describes the old four-container design)

## Not in this plan

- **PLAN-system-registry-cache-002-cluster-wiring**: rendering `registries.yaml` / containerd
  `hosts.toml` so a cluster actually uses this cache. Not written yet — the backlog investigation's
  F3 has the k3s-side config shape, but it hasn't been validated against a real UIS-provisioned
  cluster the way this plan's own provisioning step has been validated against Proxmox.
- **PLAN-system-registry-cache-003-warm-verify**: the actual outage acceptance test (block egress on
  both the cache and a cluster node, delete a cached image, confirm it still pulls). Also not
  written — warming an image into the cache (this plan) is not the same claim as a cluster surviving
  an outage through it, and that gap should stay visible until someone closes it for real.
