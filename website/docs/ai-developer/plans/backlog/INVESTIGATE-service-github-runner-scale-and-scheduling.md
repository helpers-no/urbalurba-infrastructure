---
title: "github-runner: scale-to-zero and capacity-aware scheduling"
status: backlog
type: INVESTIGATE
area: service
severity: medium
created: 2026-10-30
---

# github-runner: scale-to-zero and capacity-aware scheduling

**Proposed by**: ops (`urb-agents#2073`), relaying Terje's direction after live
debugging of bifrost's second registration (`urb-agents#2067`/`#2071`/`#2072`).
Filed as a design question, explicitly **not** a request for immediate action —
"flagging for whoever picks up github-runner next."

## What prompted it

bifrost registered a second `github-runner` instance on the shared Proxmox k3s
cluster (`urb-agents#2067`, `./uis github-runner register bifrost
terchris/bifrost`). Getting its first real CI job (a Yarn/Turborepo monorepo
install+build) to run clean took three rounds of live debugging on `ops`'s side
(`#2071`, `#2072`):

1. First failure looked like OOM (2Gi limit) — bumped to 4Gi, no change.
2. Second failure at the same wall-clock point turned out to be one of the
   cluster's test nodes going `NotReady` mid-job (node instability, tracked
   separately by ops) and evicting the pod — not a resource problem at all.
3. Third retry hit a **genuine** OOM (`exitCode=137`, confirmed via container
   status) — but specifically because it landed on a test node with under
   4GiB total allocatable RAM. The same 4Gi container limit on a different,
   much larger test node would likely have been fine.

Terje's read, from watching this: *"we want runners to be active only when
needed and to run on the machine that has the best capacity."* Two distinct
asks, neither solvable by tuning `645-setup-github-runner.yml`'s existing
knobs (`github_runner_memory_request`/`_limit`) as-is.

## Ask 1 — active only when needed (scale-to-zero)

`645-setup-github-runner.yml`'s current shape is a static `Deployment`: one
always-on pod per instance, permanently polling GitHub for jobs whether or not
one is queued. Cheap at one instance (urb-agents' own low-volume CLI-release
runner); the cost is now per-instance and additive as more repos register
(bifrost today, presumably more later) — each a permanent reservation on the
shared cluster, 24/7, regardless of how often it actually runs a job.

GitHub's **Actions Runner Controller (ARC)** is the standard answer: an
operator that creates an ephemeral runner pod per queued job and tears it down
after. Open question this investigation exists to answer: does ARC **replace**
`645-setup-github-runner.yml` outright, or **coexist** with it for instances
that genuinely want always-on (is there one? urb-agents' own instance currently
has no stated reason to need always-on over ARC's reactive model)? ARC is a
different architecture, not a flag on the current Deployment — this is a real
design decision, not a tuning pass.

## Ask 2 — run on the machine with the best capacity

Not achievable today, independent of ask 1. The fleet's three test k3s nodes
are identically-sized 4096 MB VMs, while their underlying hypervisors differ
hugely in free capacity (one single-digit GB free, another well over 15GB
free at the time of `#2073` — live numbers from ops's own capacity-reporting
playbook, committed the same day). There is no "biggest node" for the k8s
scheduler to prefer, because the *nodes themselves* are sized identically
regardless of what sits under them — a `nodeSelector`/affinity rule has
nothing real to discriminate on yet.

bifrost's genuine OOM landed on the tight-hypervisor node specifically because
that node's total allocatable RAM is *less than* the container's own 4Gi limit
— raising the container limit further cannot fix that on that node; it can
only help on a node that actually has the headroom to back it.

ops's own framing of the two non-exclusive fixes (not picked yet — Terje's or
whoever owns this call):

1. Bump the container memory limit further (6–8Gi) **and** pin the runner away
   from the tight-hypervisor node toward one of the others
   (`nodeSelector`/affinity).
2. Leave memory as-is and reduce the build's own footprint (capped `yarn
   install`, split the Turborepo build into smaller sequential steps).

Sizing the k3s-test nodes unevenly to reflect real hypervisor headroom (or
adding RAM to the test cluster itself) is the node-level half of the same
question — separate from, but a precondition for, any scheduler-side
preference actually having something real to act on.

## What this affects

Every `github-runner` instance on the cluster — urb-agents' own and bifrost's
today, whichever repo registers next. Not scoped to bifrost's specific build.

## Explicitly out of scope here

A test node going `NotReady` under load mid-job (the node-stability issue
that caused the *second* failed run in `#2072`) is ops's own, separately
tracked instability investigation — a live symptom this debugging surfaced, not
part of the scale-to-zero/scheduling design question itself.

## Status

Filed, unstarted. No design chosen for either ask. Needs a product/cost
decision (ARC adoption is an architecture change, not a patch) before any
implementation work is scoped.

## Related

- `urb-agents#2067` — bifrost's registration (the generic `uis github-runner
  register/remove/list` CLI, `urb-agents#2053` follow-on)
- `urb-agents#2071`, `#2072` — the live OOM/eviction debugging this was found
  during
- `urb-agents#2073` — ops's filing of this design question
