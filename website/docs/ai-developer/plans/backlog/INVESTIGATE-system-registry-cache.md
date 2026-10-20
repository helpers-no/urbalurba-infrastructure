# Investigate: Registry cache — a UIS cluster cannot currently restart without the internet

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: Give UIS a pull-through registry cache so a cluster can restart,
reschedule and self-heal with no internet access — and so repeated deploys stop
re-downloading the same layers and stop being subject to Docker Hub rate limits.
UIS has no registry mirror concept today; a working reference implementation was
built and outage-tested on a production Proxmox deployment, and the findings
(including two non-obvious traps) are recorded here.

**Related**: [INVESTIGATE-system-observability](./INVESTIGATE-system-observability.md),
[INVESTIGATE-system-remote-deployment-targets](./INVESTIGATE-system-remote-deployment-targets.md)
**Created**: 2026-08-05 — built and verified on k3s cluster `asgard` / Proxmox host `odin`

---

## Background

A UIS deployment pulls images from `registry.k8s.io`, `docker.io`, `ghcr.io` and
`quay.io`. On the production cluster surveyed, **41 distinct images** across those
four upstreams.

There is no mirror or cache anywhere in UIS:

```bash
grep -rl 'registries.yaml\|registry-mirror\|pull-through' .   # → no matches
```

### The failure mode this creates

If upstream registries are unreachable — an outage, an ISP problem, a rate limit,
or simply an air-gapped site — then:

- **already-running pods keep running** (their layers are on the node), so nothing
  looks wrong at first;
- **any restart, reschedule, node reboot or scale-up fails to pull**, and the
  affected service stays down until connectivity returns.

That is the worst shape of failure: invisible until the moment you need recovery,
and it hits hardest exactly when other things are already broken.

### Three reasons this matters beyond outages

1. **Docker Hub rate limits.** Anonymous pulls are throttled per IP. A cluster
   redeploying a stack, or several developers on one office IP, can hit the limit
   and see confusing `toomanyrequests` failures mid-deploy.
2. **Bandwidth and time.** Redeploying the observability stack alone re-pulls
   ~2 GB. A cache makes repeated installs and rebuilds dramatically faster.
3. **Developer laptops benefit too.** Rancher Desktop supports registry mirrors,
   so one cache on the network speeds up every `uis deploy` for everyone — not
   just production.

---

## Part 1: Findings from the reference implementation

### F1 — The cache must live OUTSIDE the cluster (architectural, not preference)

A registry running *inside* the cluster cannot serve the images required to start
that cluster. After a cold boot, the cache's own pod needs an image, which needs
the cache. Same bootstrap circularity as an in-cluster secret store.

**Implication for UIS:** a registry cache is **not a service** in the
`uis deploy <service>` sense. It belongs to the **host/platform layer** — alongside
the things UIS provisions *around* a cluster. This may need a new concept, or it
fits naturally under host/target management.

*(In-cluster P2P alternatives such as `spegel` share already-pulled layers between
nodes and are useful, but they cannot solve the cold-start case and are irrelevant
on a single-node cluster.)*

### F2 — `registry:2` proxies exactly one upstream, so N upstreams need N instances

`REGISTRY_PROXY_REMOTEURL` is singular. The reference build runs four containers:

| Port | Upstream |
|---|---|
| 5000 | `https://registry-1.docker.io` |
| 5001 | `https://registry.k8s.io` |
| 5002 | `https://ghcr.io` |
| 5003 | `https://quay.io` |

Workable but clunky. **Alternatives worth evaluating before implementing:** `zot`
(CNCF, supports multiple upstream sync targets in one instance), `Harbor` (heavy,
but full-featured with GC and auth), or `docker/distribution` behind a router.

### F3 — k3s wiring is simple and well-defined

`/etc/rancher/k3s/registries.yaml`:

```yaml
mirrors:
  docker.io:
    endpoint: ["http://<cache-host>:5000"]
  registry.k8s.io:
    endpoint: ["http://<cache-host>:5001"]
  ghcr.io:
    endpoint: ["http://<cache-host>:5002"]
  quay.io:
    endpoint: ["http://<cache-host>:5003"]
```

k3s generates `/var/lib/rancher/k3s/agent/etc/containerd/certs.d/<registry>/hosts.toml`
from this on restart. Verified: pulls route through the cache and the upstream
remains the fallback. (Rancher Desktop accepts the same file, and other distros
have equivalents — so the concept is portable across UIS's cluster types.)

### F4 — ⚠️ `crictl pull` does NOT warm the cache (the trap)

**This cost real time and produced a false positive.** `crictl pull` is a no-op
when the image is already present on the node — it never contacts the mirror.
A warming loop over all 41 images reported:

```
pulled ok=41  failed=0
```

…while the cache actually contained **4 repositories**. Confirmed by querying the
registry rather than trusting exit codes:

```bash
curl -s http://<cache>:5000/v2/_catalog
{"repositories":["library/busybox","library/postgres","library/redis"]}
```

**The reliable method is to request each image *from the mirror endpoint*,** which
forces it to fetch and store:

```bash
skopeo copy --src-tls-verify=false \
  docker://<cache-host>:5000/library/redis:7.4 dir:/tmp/warm && rm -rf /tmp/warm
```

After doing it properly: **42 repositories, ~2 GB**.

**Any `uis registry warm` implementation must verify via `/v2/_catalog`, not via
the pull command's exit status.**

### F5 — Official Docker Hub images need `library/` inserted

`docker.io/redis:7.4` maps to `<cache>:5000/library/redis:7.4`, not
`<cache>:5000/redis:7.4`. This was the single failure in the warming run. Any
image→mirror path translation needs to handle: bare name (`nginx`), `org/repo`,
and fully-qualified `docker.io/...`, `ghcr.io/...` etc.

### F6 — Outage behaviour, verified

With internet egress blocked (nft drop to everything outside the LAN) on **both**
the cache host and the cluster node, an image was deleted from the node and
pulled again successfully from cache. This is the test any implementation should
ship as its acceptance criteria — it is the only way to know the cache is real.

### F7 — Sizing and lifecycle

~2 GB for 42 repositories of a 13-service platform. Cache storage should live on
snapshotted/backed-up storage if cheap, but it is **reconstructible** — so it is
a candidate for exclusion from offsite backup.

No garbage collection is configured in the reference build. `registry:2` needs
`REGISTRY_STORAGE_DELETE_ENABLED=true` plus a periodic `registry garbage-collect`
run, or the cache grows without bound as tags churn.

---

## Part 2: Proposed plans (ordered)

```
PLAN-system-registry-cache-001-provision.md      ← written 2026-10-05, Status: Backlog, ready to implement
PLAN-system-registry-cache-002-cluster-wiring.md ← generate registries.yaml on provision — not written yet
PLAN-system-registry-cache-003-warm-verify.md    ← `uis registry warm` + outage test — not written yet
```

> **Update, 2026-10-05:** [PLAN-system-registry-cache-001-provision.md](./PLAN-system-registry-cache-001-provision.md)
> now exists and is ready to implement — see it for the resolved engine decision (zot, not
> `registry:2` — open question 1 below) and a validated reference implementation to port from
> (`platforms/proxmox/ansible/roles/registry/`, built and verified against a real 3-node Proxmox
> lab, outside UIS proper). PLAN-002 and PLAN-003 are still unwritten; their scope below remains
> accurate.

### PLAN-001 — Provision the cache

Decide the engine (see F2) and where it runs. Because of F1 it cannot be a
cluster service; candidates are a small VM/container on the same host, or a role
added to the host templates from
`INVESTIGATE-system-remote-deployment-targets`.

*Acceptance:* a documented, reproducible cache reachable from the cluster,
surviving host reboot.

### PLAN-002 — Wire clusters to it automatically

Render `registries.yaml` (or the distro equivalent) during cluster provisioning,
from a cache endpoint configured in `.uis.extend`. Must degrade gracefully: no
cache configured ⇒ current behaviour, unchanged.

*Acceptance:* a freshly provisioned cluster pulls through the cache with no
manual file editing; `certs.d/*/hosts.toml` is present.

### PLAN-003 — `uis registry warm` and verification

A command that enumerates images in use (or in the enabled service set) and warms
them **via the mirror endpoints** (F4), handling path translation (F5), then
reports what is actually cached from `/v2/_catalog`. Plus a documented outage test
(F6) and a GC policy (F7).

*Acceptance:* `uis registry warm` reports cached repository counts that match the
enabled services; the outage test passes.

---

## Part 3: Open questions

1. ~~**Engine:** four `registry:2` instances, or one multi-upstream tool (`zot`)?~~ **Resolved
   2026-10-05: zot.** One instance fronting every upstream beats adding a container+port+GC-unit
   per upstream forever — see PLAN-001. Harbor was also considered and ruled out (needs its own
   Postgres+Redis).
2. **Where does a non-cluster component live in the UIS model?** This is the
   interesting design question — UIS's unit of composition is an in-cluster
   service, and this cannot be one. Same shape as an external database, external
   object store, or the secret store: a growing class of "platform components
   beside the cluster" that may deserve first-class support.
3. **Private registries.** `ghcr.io` pulls of private images need credentials in
   the cache. Out of scope for a first pass, but worth designing for.
4. **TLS.** Plain HTTP is acceptable on a trusted segment (and simplest), but
   `containerd` needs explicit configuration for insecure endpoints on some
   distros. TLS with an internal CA is the cleaner end state.
5. **One cache for many clusters?** A single cache serving production, dev
   laptops and CI multiplies the benefit — but makes it a shared dependency, so
   it should fail open (upstream fallback) rather than closed.
6. **Retention/GC defaults** so the cache cannot fill the disk it shares.

---

## Part 4 — Forgejo/Epinio needs a *different* shape, not another upstream (2026-10-19)

**From `urb-agents#1912`:** whichever cluster ends up running Epinio
([INVESTIGATE-service-epinio-deploy-path](./INVESTIGATE-service-epinio-deploy-path.md))
needs containerd to trust Forgejo's own built-in OCI registry without TLS — the same
*class* of gap as open question 4 above, but **it is not another entry in
`registry_upstreams`**, and folding it in that way would actively break things:

- `registry_upstreams` is synced by zot with `tlsVerify: true`
  (`roles/registry/templates/zot-config.json.j2`). Forgejo serves plain HTTP internally
  (no `cert-manager` in UIS; TLS ends at the edge) — a `tlsVerify: true` sync against it
  does not work.
- Even with that relaxed, zot re-encodes Docker-format images to OCI on ingest — the
  OCI-REFORMAT CAVEAT already recorded in `roles/registry/defaults/main.yml`. **A
  digest-pinned pull does not hit the cache.** Forgejo's own images are exactly the case
  most likely to be pulled by digest (build → push → deploy in one pipeline), so routing
  them through zot risks silently missing the cache on every pull, not just the first.
- Conceptually, Forgejo is the **origin** of these images, freshly built locally — not an
  external upstream being mirrored for resilience. `registry_upstreams`'s own stated
  purpose is "cache every image this lab ever deploys … from upstreams nobody's picked
  yet"; Forgejo isn't one.

**Recommendation:** a second, independent variable — e.g. `registry_direct_insecure: []`,
a list of `{domain, endpoint}` with nothing to do with zot — rendered into the *same*
`/etc/rancher/k3s/registries.yaml` by a generalized `k3s-registries.yaml.j2` /
`k3s-registry-ensure.yml`, as containerd's standard shape for a private insecure
registry: a domain mirrored to itself over plain HTTP
(`mirrors: { <forgejo-domain>: { endpoint: ["http://<forgejo-host>:<port>"] } } }`),
not proxied through zot at all.

⚠️ **The risk this surfaces, not yet solved:** `k3s-registry-ensure.yml` runs exactly
once, gated on `"registry" ∈ CORE_SERVICES`, and **writes the whole file** via
`ansible.builtin.template` — the full desired state comes from `registry_upstreams`
alone, today. If Forgejo/Epinio wiring is triggered independently (a second playbook run
against the same file, from whatever eventually provisions Forgejo), each run clobbers
whatever the other wrote — there is exactly one `registries.yaml` per node, and only one
of the two conditions can win a last-write-wins race.

**The fix is composition, not a second file.** Whatever ends up triggering Forgejo's
registry wiring must assemble the complete desired state in one render — both the
zot-mirror entries (if `registry` is selected) and the direct-insecure entries (if
Forgejo/Epinio is selected) — rather than each trigger owning an independent write to the
same path. This is not yet resolved because it is not yet decided whether Forgejo
provisioning becomes a `CORE_SERVICES` entry in `05-core-services-apply.sh`'s sense or a
separate mechanism entirely (`urb-agents#1911`'s territory). **Flagging the clobber risk
now, before that decision locks in a shape that hits it.**

Not a PLAN yet — gated on the same lab proof-of-concept as the Epinio deploy-path
decision.

---

## Part 5 — the clobber risk crosses a repo boundary, not just a trigger boundary (2026-10-19)

**From a review on `urb-agents#1913`:** Part 4's clobber risk was analysed *within this
repository's own scope* — the existing zot-triggered write versus a possible future
Epinio-triggered write, both living in `urbalurba-infrastructure`. That framing has a gap:
**this repository's own `k3s-registry-ensure.yml` is itself just one possible writer of
`/etc/rancher/k3s/registries.yaml`.**

Nothing about that playbook detects or preserves entries it did not put there. It
templates the whole file from `registry_upstreams` (plus, per Part 4's recommendation,
whatever direct-insecure list it's given) and overwrites unconditionally. **If a cluster's
`registries.yaml` is composed or managed by anything outside this repository's own
`05-core-services-apply.sh` flow — for any reason, including one this document has no
visibility into — re-running this playbook against that cluster silently discards
whatever that other process added, with no warning.** The playbook's own verification step
only checks that *its configured* upstreams have `certs.d/`; it does not check that
nothing else was removed.

Part 4's fix (one render, one combined list, covering both zot-mirror and direct-insecure
entries) only closes the gap **for callers inside this repository's own invocation of the
playbook.** It says nothing about a second, independent writer that isn't this repo's code
at all — and this document cannot know, let alone decide, what such a writer would be or
whether one exists for a given deployment. That is a real limit on what an INVESTIGATE
filed here can resolve, not an oversight to paper over.

**What this repository's own mechanism can still do, regardless of who else might write
to this path:**

1. **Accept the direct-insecure list as an explicit input**, not only from in-repo
   defaults — so *any* caller, whether the eventual Epinio/Forgejo trigger lives in this
   repo or not, can supply its entries through this one playbook invocation instead of
   writing the file independently. (This generalizes Part 4's recommendation rather than
   replacing it.)
2. **Refuse rather than silently overwrite what it doesn't recognize.** Before templating,
   read the current file if one exists, and compare its mirror domains against the known
   set (configured upstreams plus any supplied extras). An unrecognized domain means
   something else is managing this file — **refuse, naming it**, rather than discarding
   it. This is the same shape as this repository's own precedent elsewhere (`uis argocd
   register` asking what is actually *in* a namespace before acting, rather than trusting
   whether it merely exists) — a refusal that names the surprise beats a success that
   doesn't mention it.

**What this document explicitly does not resolve:** whether anything outside this
repository's own apply flow is ever expected to manage entries in this file for a given
deployment, and if so, whether it would route through this playbook (per recommendation 1
above) rather than writing independently. That is not a decision this repository's own
backlog can make unilaterally — it depends on whatever mechanism ends up owning Forgejo's
entry, which per `INVESTIGATE-service-epinio-deploy-path.md` is still unsettled. Recording
it here so it is a deliberate choice, not a silently-reverted file discovered the next time
`05-core-services-apply.sh` runs with `registry` selected.

---

## Part 4/5 are now IMPLEMENTED, not just designed (2026-10-20)

Both recommendations above are built, in `platforms/proxmox/ansible/playbooks/`:

- `templates/k3s-registries.yaml.j2` now renders two independent loops — the existing
  zot/`registry_upstreams` one (only when `registry_host` is non-empty) and a new one over
  `registry_direct_insecure` (a plain `{domain, endpoint}` list, mirrored to itself over
  plain HTTP, no zot involvement at all).
- `k3s-registry-ensure.yml` accepts `registry_direct_insecure` as an explicit `-e` input
  (default `[]`, declared in the playbook's own `vars:` — deliberately **not** added to
  `roles/registry/defaults/main.yml`, since it has nothing to do with zot). The old
  mandatory `registry_host` assert is relaxed to "at least one of the two mechanisms must
  be requested," so a caller with only a direct-insecure entry and no zot cache doesn't
  need to pass a meaningless `registry_host`.
- **The refuse-on-unrecognized-domain safety net is in**: before templating, the playbook
  reads the node's existing `registries.yaml` (if any), and refuses — naming the domain —
  if it already mirrors something neither `registry_upstreams` nor the supplied
  `registry_direct_insecure` accounts for. This is this repository's own answer to the
  Part 5 cross-repo risk: it cannot stop another repo's tooling from writing this file
  independently, but it can refuse to silently clobber whatever that tooling left behind,
  rather than discovering the overwrite later.
- The certs.d verification loop now covers both kinds of domain, not just zot's.

⚠️ **What this is not**: proof that it works against a real cluster. Verified so far —
`ansible-playbook --syntax-check` on the playbook, and the Jinja template itself rendered
standalone (via `jinja2`, outside Ansible) against three cases (zot-only, direct-insecure-
only, both) and parsed back as valid YAML with the expected `mirrors:` keys in each. The
`set_fact` expressions inside the playbook (the `ternary`/`difference`/`from_yaml` chain)
were reviewed but not executed under real Ansible, and none of this has run against an
actual k3s node — no live cluster exists in the environment this was built in. The
2026-10-05 zot-only path this replaces was verified live; this generalization has not been,
and that gap stays open until someone runs it for real.

Still not resolved here, same as Part 5 left it: whether anything outside this
repository's own apply flow is expected to manage this file for a real deployment, and
whether `05-core-services-apply.sh` itself gets wired to call this generalized playbook for
a Forgejo-owning service — that's the orchestration layer, intentionally left to whoever
integrates this with an actual Forgejo-provisioning service.

---

## Appendix: reference implementation as built

Proxmox LXC (2 cores, 1 GB RAM, 60 GB cache volume on ZFS with 1 M recordsize +
zstd), Docker running four `registry:2` pull-through caches with
`--restart=always`, cluster wired via `registries.yaml`. Warmed with `skopeo` to
42 repositories / ~2 GB. Outage-tested by blocking egress on both the cache and
the cluster node. Cache volume is snapshotted and included in guest backups,
though it is fully reconstructible.
