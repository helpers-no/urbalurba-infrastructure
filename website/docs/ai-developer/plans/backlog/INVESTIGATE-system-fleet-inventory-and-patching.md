# Investigate: a context-aware fleet inventory, and what "patch" means once a service is a container

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: Decide whether UIS should have a single inventory tool that reports
different things depending on where it runs (a Proxmox host vs. a Kubernetes
context), and — the harder question underneath that — decide what "this needs
patching" even means once the thing being asked about is a container rather
than a machine.

**Origin**: Terje, 2026-10-05, in conversation: *"is it possible to have a IaC
that reads out all info in the 3 proxmox servers if it is run there. if it is
run in rancher desktop it should inventory what is there... eg if there is a
postgres server. must the server itself be patched?"*

**Related**:
[INVESTIGATE-service-semaphore](./INVESTIGATE-service-semaphore.md) — the
automation surface this would most naturally run from. Same "components
beside/around the cluster" class as
[INVESTIGATE-system-registry-cache](./INVESTIGATE-system-registry-cache.md)
(F1), [INVESTIGATE-system-backup-and-scheduling](./INVESTIGATE-system-backup-and-scheduling.md),
[INVESTIGATE-system-monitor-definitions-with-services](./INVESTIGATE-system-monitor-definitions-with-services.md)
and [INVESTIGATE-service-uptime-kuma](./INVESTIGATE-service-uptime-kuma.md)
(F8) — each of those named a gap in what `uis deploy` can express about
infrastructure that is not a cluster service; this is the patching version of
the same gap, one layer down (a *host*, or a *container image*, not a
cluster-shaped component).
[INVESTIGATE-system-version-pinning](./INVESTIGATE-system-version-pinning.md)
— adjacent but distinct: that document is about *pinning* charts/images so
upstream does not move without warning. This document is about what happens
**after** something is pinned — how an operator finds out a newer version
exists, and how they move the pin forward safely. A pinned version with no
way to advance it just freezes the drift problem instead of solving it.

**Created**: 2026-10-05

---

## Questions to Answer

1. Can one script reliably tell whether it is running on a Proxmox host or
   against a Kubernetes context, and report the right thing for each?
2. For a service UIS deploys as a container, what does "needs patching" even
   mean — is there a single mechanism, or two?
3. Should any of this be automated, and if so, how much — all the way to
   "applies it," or only as far as "tells a human it exists"?
4. Where does this run from, and who looks at the output?

---

## Background

No inventory tool exists anywhere in this repo today:

```bash
grep -rli "inventory\|fleet-survey" provision-host/uis/lib/ provision-host/uis/manage/
# -> nothing that reads host or cluster state for its own sake
```

`provision-host/uis/lib/monitors.py` *discovers* services (it has to, to
generate monitors), but its discovery is narrow and single-purpose: it
resolves a Service to a reachable address and stops there. It does not
report, and currently has no reason to report, what image or version is
actually running.

Separately — read directly, read-only, against a real production instance
that already does something adjacent to what was asked for — a reference
implementation exists for exactly half of this (the Proxmox half) and the
same estate's own Ansible library has spent real incidents learning what
"patch" has to guard against on the host side. Both are described below
generically; neither is reproduced verbatim, and no project/host-naming
detail from either is repeated here.

---

## Part 1: The inventory half — findings

### F1 — A Proxmox-mode survey is a solved shape, and it is read-only by construction

A read-only fleet survey against Proxmox is buildable entirely through the
Proxmox API using a **scoped, audit-only token** (Proxmox's built-in
`PVEAuditor` role: list/read, no `Sys.Modify`, no write path at all — the tool
cannot touch what it inspects even if its own logic is wrong). Observed
structure, generalized:

- per-node: uptime, kernel version, **pending-reboot derived by comparing the
  running kernel against the boot-loader's recorded one** — not the
  `/var/run/reboot-required`-style flag file, which a kernel-only update does
  not always create
- per-disk: SMART health and wear remaining, flagged when either looks wrong
- per-ZFS-pool: health and capacity, flagged near-full
- per-guest (VM/LXC): status, allocated vs. actual resource use
- backup task history (the hypervisor's own scheduled-backup log), flagged
  when a recent run failed **or when none ran at all** — a job that silently
  stopped running must not read the same as a job with nothing to report
- three output shapes from one source of truth: everything, problems-only,
  machine-readable

None of this needs root or a write-capable credential. The whole survey is a
read of state Proxmox already tracks.

### F2 — The Kubernetes-mode half is a smaller lift than it looks, because it is already half-built

`monitors.py`'s `load_cluster()` / `deployed_services()` already answer "what
is UIS running, and where" for the monitoring subsystem's purposes. The gap
for a general inventory is narrow: today that discovery stops at *name →
reachable address*. A general inventory additionally wants, per workload:
**image reference and tag**, replica/ready counts, and restart counts — all
of which `kubectl get pods -o json` already carries; nothing needs inventing,
only reading one layer deeper than `monitors.py` currently bothers to.

### F3 — Mode detection is a one-line question, not a design problem

`/etc/pve` (or a working `pvesh`) existing is Proxmox-specific and reliable.
A live `kubectl` context is the Kubernetes-mode signal. The two are not
mutually exclusive in principle (a Proxmox host could theoretically also have
a kubeconfig on it), so mode should be an explicit choice with auto-detection
as the default, the same pattern `monitors.py` already uses for `--watchdog
auto|in-cluster|external`.

---

## Part 2: The patching half — this is where the real question lives

### F4 — "Patch" is not one mechanism. It is (at least) two, and they do not share a verb

| | A bare host / VM | A container UIS deployed |
|---|---|---|
| What "patching" changes | OS packages, via the package manager | The image reference in a manifest/values file |
| How you find out something is pending | `apt list --upgradable` / the hypervisor's own update check | Comparing the pinned tag against upstream's published tags/releases |
| How you apply it | SSH in, `apt-get upgrade <set>`, possibly reboot | Edit the pin, `kubectl apply` / `helm upgrade`, roll the pod |
| What can go wrong applying it | A config file prompt hangs the session; a kernel update needs a reboot the file-flag does not always report | A **major** version bump can need `pg_upgrade` or a dump/restore, not just a tag swap — this is real for Postgres specifically, not a hypothetical edge case |
| Does UIS have any of this today | No automation, but the hard parts (consent gating, scope verification, two-source reboot-required check) are a solved, proven pattern elsewhere — see F5 | **Nothing.** No check for a newer tag, no safe-upgrade path, no distinction between "safe to automate" and "needs a human" |

So the direct answer to the question that opened this investigation —
*"if there is a postgres server, must the server itself be patched?"* — is:
**there is no server to apt-patch.** UIS's `postgresql` service is a
container; it has no sshd, no apt, nothing to SSH into. What *does* still
need OS-level patching is the Kubernetes **node** that container's pod runs
on (the Proxmox VM/host, or the Rancher Desktop VM in dev) — a target F1/F5
already cover. The container's own base-OS packages only move when upstream
publishes a new image layer, which is purely a "newer tag" question, answered
by F6, not by anything SSH-shaped.

### F5 — The host-patching half already has a proven, hard-won safety pattern worth lifting wholesale

Read directly from the reference estate's own Ansible library (generalized;
no host names or incident references reproduced): a `patch` playbook that —

- **refuses to run without an explicit consent reference** — a record of who
  agreed to this specific run, not an inferred default
- **patches one host at a time**, hard-stopping the whole run on the first
  failure rather than continuing across a fleet
- **computes "security scope" from the actual update-pocket metadata**, not
  from package names — and separately *verifies the computed set still
  matches what consent was given for*, refusing if it drifted between the
  two
- **checks reboot-required from two independent sources**, because the
  standard flag file does not fire for every kernel-update shape (observed
  directly: a Raspberry Pi OS kernel round left the flag file saying "no"
  while the system's own restart-advisory tool correctly said "yes, a kernel
  is pending")
- treats reboot as a **separate consent** from patch, since each is its own
  outage

Every one of these is a real defect this investigation found already fixed,
not a theoretical best practice — the same discipline that produced the
`monitors.py` fixes in this repo's own `fix/monitors-apply-shrink-drift-safety`
branch. This half of the problem does not need research; it needs porting,
generically, into UIS's own automation surface (most naturally, a Semaphore
example playbook — see
[INVESTIGATE-service-semaphore](./INVESTIGATE-service-semaphore.md)).

### F6 — The image-tag half does not exist anywhere yet, and is the part that actually needs deciding

Three sub-questions, not one:

1. **How does anything find out a newer tag exists?** Per-chart/image, this
   is a registry query (Docker Hub / GHCR tag list, or a Helm chart repo
   index) compared against the pin in
   [INVESTIGATE-system-version-pinning](./INVESTIGATE-system-version-pinning.md)'s
   inventory. Nothing in this repo does that query today.
2. **What is safe to bump automatically, and what needs a human?** A patch
   release is usually safe. A minor release, usually safe but worth a changelog
   read. A **major** release is the Postgres case: `pg_upgrade` or dump/restore,
   a real outage shape, and arguably never auto-applied.
3. **What does "applied" even verify?** Not "the pod is Running" — the same
   lesson F5's reboot-required check already demonstrates (the shallow signal
   lies). For a database specifically: did the schema version advance, does
   the application still connect, does a smoke query still return the right
   shape.

None of these three has an answer in this repo yet. This is the part worth a
deliberate decision before building anything, not the inventory half (F1-F3),
which is close to mechanical.

---

## Options

### Option A: Build the inventory tool now; leave patching as a later, separate decision

**Pros:** inventory is low-risk, mostly read-only by construction, and is
useful on its own (it is the thing that tells you a Postgres instance exists
and where, before you can even ask whether it needs attention). Does not
block on F6's harder questions.
**Cons:** "once it knows what exists, what next" is the question Terje
actually asked, and shipping only the survey half answers it partially.

### Option B: Build both halves together, per the shape of the host-patching half (F5) that already works

**Pros:** one coherent deliverable — survey, then for hosts, patch, using the
already-proven pattern.
**Cons:** conflates a near-mechanical piece (inventory) with one that still
needs real design decisions (F6), and the container-image half has no
pattern to port, so "together" would mean inventing it under time pressure
rather than deciding it deliberately.

### Option C: Split into two PLANs from this one Investigation — survey first, host-patching second (porting F5), image-tag patching deferred to its own Investigation

**Pros:** matches PLANS.md's own guidance to split a large initiative by risk
and dependency; each PLAN ships something complete on its own; the genuinely
undecided part (F6) gets the deliberate design pass it needs instead of being
bolted on.
**Cons:** more documents to track; the full "what should I patch" picture
does not exist until all three land.

---

## Recommendation

**Option C.** The inventory half and the host-patching half are both
low-risk, evidence-backed, and ready to plan now. The image-tag half is
genuinely undecided — automate how much, verify how, Postgres-major-upgrade
how — and deserves its own Investigation rather than an answer invented while
building something else.

Proposed plans, in dependency order:

```
PLAN-system-fleet-inventory-001-dual-mode-survey.md   <- F1-F3: the context-aware inventory itself
PLAN-system-fleet-inventory-002-host-patching.md      <- F4/F5: port the proven patch/reboot pattern,
                                                          generically, as Semaphore example content
INVESTIGATE-system-image-tag-patching.md              <- F6, its own document: what to automate,
                                                          how to verify, how a major version (the
                                                          Postgres case) is handled differently
```

### PLAN-001 — Dual-mode survey

A single tool, mode auto-detected (`/etc/pve`/`pvesh` present → Proxmox mode;
a live `kubectl` context → Kubernetes mode; override either way). Proxmox
mode follows F1 exactly, via a scoped `PVEAuditor` token. Kubernetes mode
extends `monitors.py`'s existing discovery one layer deeper (image/tag,
ready/restart counts), reusing `load_cluster()`/`deployed_services()` rather
than re-discovering services from scratch.

*Acceptance:* run on a Proxmox host, reports host/guest/storage/backup state
with zero writes; run against a Kubernetes context, reports every UIS-deployed
service with its current image tag; both modes offer full / problems-only /
machine-readable output.

### PLAN-002 — Host patching

Generic (no real hostnames/incident references), ships as example Semaphore
content per
[INVESTIGATE-service-semaphore](./INVESTIGATE-service-semaphore.md) Part 4's
pattern: consent-gated, one-host-at-a-time, security-vs-all scope with
drift verification against the consented set, two-source reboot-required
check, reboot as a separate consent from patch.

*Acceptance:* refuses to run without a consent reference; refuses if the
computed update set has moved since consent; correctly reports
reboot-required on a kernel update that the flag file alone would miss.

### Image-tag patching — a new Investigation, not a PLAN yet

Needs its own Questions-to-Answer pass: per-service automate/flag policy,
what "verified" means beyond pod-Running per service class, and a concrete
answer for the Postgres major-version case specifically, before any PLAN is
written against it.

---

## Open Questions for the Maintainer

- Does the dual-mode survey belong in `provision-host/uis/lib/` (a first-class
  `uis` subcommand) or ship only as Semaphore/example content, given it is
  read-only and arguably useful outside any Semaphore install at all?
- Is a Proxmox `PVEAuditor`-scoped token something UIS should help provision
  (a documented one-time setup step), or is that entirely the operator's own
  Proxmox administration?
- For image-tag patching specifically: should *any* service class (e.g.
  stateless, no-persistent-data services) be eligible for fully automatic
  minor-version bumps, or is "flag it, a human decides" the right default for
  everything until proven otherwise?
