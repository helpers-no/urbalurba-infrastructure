# Investigate: generic monitoring + patch/image-currency tracking for pod-based UIS services

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog — explicitly on hold, not started

**Goal**: Decide whether/how UIS should have a generic mechanism, analogous to
what ops already has for host-based services, that lets any pod-based UIS
service declare "here's how to check I'm actually working (not just that my
pod is Ready)" and "here's my pinned image version" — surfaced generically,
not built per-service by hand.

**Created**: 2026-10-26 (`urb-agents#2033`, ops, on Terje's word)

**Priority**: None assigned — **explicitly held, not to be started**. Terje's
own instruction, relayed by ops: "do not start this now... keep it on your
list so it doesn't get forgotten." No deadline, no urgency. This file exists
so the problem and the reference material behind it aren't lost before
someone picks it up, not as a signal to begin.

---

## The gap, found live building `github-runner` (`urb-agents#2030`)

Two pod-based UIS services now run continuously in production:
`forgejo-runner` and `github-runner` — persistent Deployments, not jobs; they
sit online 24/7 the same way a VM would. Neither has any monitoring or
patch/image-currency tracking. Confirmed directly by ops:

- No Kuma entry for either (Kuma there only watches declared *hosts*, not
  workloads running inside them).
- No entry in `uis status`'s health table.
- No GitHub webhook/notification on runner-offline.
- Zero scheduled check of `gh api .../actions/runners` or the
  Forgejo-equivalent (`forgejo actions list-runners` / the Forgejo API) —
  today this is 100% manual/ad hoc (ops, by hand, across the whole
  `urb-agents#2022`→`#2032` investigation).
- No tracking of whether `ghcr.io/actions/actions-runner:2.337.0` /
  `code.forgejo.org/forgejo/runner:13.2.0` are still current.

This is a UIS-wide structural gap, not specific to these two services — any
future pod-based service with the same "runs continuously, has its own
external registration/currency state" shape (a persistent Deployment, not a
Job or a stateless web app) would have the identical blind spot.

## How ops does the equivalent for Proxmox/host-based services — the pattern worth generalizing

Two orthogonal, fully generic mechanisms, both keyed off
`platform/ansible/inventory/hosts.yml`'s declared hosts, both auto-registered
into Semaphore by one generator playbook (`semaphore-setup.yml`) with zero
manual Semaphore UI work:

**1. Patch tracking.** Any host declaring two vars — `patch_ring: <N>` and
`patch_consent: <agent>` — automatically gets a "Patch — \<host\> (ring N)"
template generated. No schedule, ever: `patch.yml` hard-refuses without
`-e consent_task=<issue>` — "silence is not consent" is a stated design
principle in that repo. A separate `survey.yml` template runs daily,
read-only, reporting what updates are pending per host — that part *can* be
scheduled, since it changes nothing.

**2. Health checks.** Any file `vars/<hostname>-health.yml` whose
`<hostname>` matches a declared host gets auto-registered as a scheduled
"Health — \<hostname\>" template. The file is entirely self-contained:
`post_cmds` (shell commands to run), `post_assertions` (jinja expressions
over the command output), plus three Semaphore-facing fields co-located in
the same file — `semaphore_description`, `semaphore_cron`,
`semaphore_extra_args`. Adding health coverage for a new host is: write the
file, nothing else — no template to hand-create, no schedule to hand-wire.

Both generators are keyed off `hostvars` (Ansible's declared-host concept) —
which is exactly why neither one ever reaches a pod. A Deployment living
inside an already-covered k3s node isn't a declared host; it's invisible to
this whole mechanism by construction, not by oversight.

## A real, already-written reference for what a pod-aware check needs

`platform/ansible/vars/ci-runner-health.yml` in ops's own repo (private,
`terchris/home` — not clonable from here, substance relayed by ops since it's
load-bearing) was written for a generic k8s-pod GitHub-runner role that was
never actually deployed (a different, earlier design than what shipped for
`urb-agents#2030`). Unused today, but a genuinely good reference for the
*shape* of a correct check, with real lessons already paid for:

- **"Pod is Ready" is the wrong primary check.** A pod is Ready the moment
  its container starts; it's useful only once the forge (GitHub/Forgejo)
  actually has it on its runner list. These come apart in both directions —
  ops's own comment on the file: "on its first real run the deployment
  rolled out, the role asserted on that rollout and passed, and the forge
  had never heard of the runner." The forge's own view (`gh api
  repos/<repo>/actions/runners`, or the Forgejo-equivalent) is the check
  that matters; pod-readiness is reported for contrast, not asserted as
  sufficient on its own.
- **The "ghost registration" trap.** Deleting the namespace once left the
  runner still listed `online` at GitHub — asserting *only* the forge-side
  check would have been a false green over a service that no longer exists.
  The fix: assert **both** "runner online at the forge" **and** "pod ready"
  — either alone can be true while nothing actually works.
- **GitHub pretty-prints its JSON** (`"status": "online"`, with a space) — a
  naive grep for `"status":"online"` silently matches zero and reports a
  confident wrong answer. Collapse whitespace before matching.
- **Container restarts should be reported, not asserted.** A runner that
  legitimately cycles isn't a fault — asserting `restarts == 0` is a
  one-way ratchet to permanently red (the same mistake another role in that
  repo already made once, per ops). `CrashLoopBackOff` specifically, not
  restart count, is the assertable form of "actually broken."
- **Image-in-use is read and surfaced** (`kubectl get deploy ... -o
  jsonpath='{.spec.template.spec.containers[0].image}'`) specifically so a
  pinned-version drift is visible in the *same* check, not a separate
  mechanism.
- One gotcha specific to ops's own box, flagged as probably not portable:
  `become: true` there strips `kubectl` from `PATH` and drops `KUBECONFIG`,
  so every command resolves both explicitly rather than trusting the
  environment.

## What this document does not decide

Deliberately nothing — this is a problem statement and reference material,
not a design. Real open questions for whoever picks this up:

- Does this belong in UIS itself (a `SCRIPT_HEALTH_CHECK`-style field a
  service script declares, surfaced by `uis status`?), or is it closer to
  ops's own Semaphore-generator pattern translated into UIS's own idiom?
  Ops's own framing: "this almost certainly belongs in
  `urbalurba-infrastructure` since it's a UIS-wide concern, not
  fleet-specific — but that's your call to make, not mine to assume."
- Scope: start with `forgejo-runner`/`github-runner` specifically (the two
  known consumers today), or design the generic mechanism first and retrofit
  both? Given `SCRIPT_CHECK_COMMAND` already exists as a per-service
  "is it up" field (see `provision-host/uis/services/*/service-*.sh`), the
  honest starting question is whether that field's own contract should grow
  to cover "actually working, not just Ready" (forge-registration,
  image-currency) or whether a distinct, additional mechanism is cleaner.
- Scheduling/surfacing: `uis status`'s existing health table is the obvious
  display surface for "is it actually working," but there's no existing UIS
  mechanism for a periodic, scheduled check the way Semaphore's cron-driven
  templates are for ops — whether that gap should be closed as part of this,
  or left to whatever already-running mechanism polls `uis status`
  (Kuma, or something else), is open.
- Patch/image-currency tracking specifically has no UIS analogue at all
  today (no "ring"/"consent" concept, no survey mechanism) — whether a
  pod-based equivalent is even wanted, or whether "redeploy picks up the
  pinned version in the playbook" is judged sufficient for pods (unlike a
  host, which needs its OS packages patched independently of any UIS
  action), is a real product question, not an implementation detail.

## Related

- `urb-agents#2022`→`#2032` — the whole `forgejo-runner`/`github-runner`
  investigation this gap was found during.
- `provision-host/uis/services/*/service-*.sh`'s `SCRIPT_CHECK_COMMAND` —
  the closest existing UIS concept, and the first thing to re-examine
  before inventing a second one.
