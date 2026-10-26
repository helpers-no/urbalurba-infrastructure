# Investigate: Forgejo Actions runner — the other half of the CI decision never got built

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Superseded (resolved 2026-10-23, not via this document's own plan)

⚠️ **The goal below was achieved, but not through PLAN-001/PLAN-002 as proposed here.**
`urb-agents#1982` built the dedicated-VM path this document describes (`08-lab-extra-add.sh`/
`09-lab-extras-apply.sh`, a VM-kind lab extra), and it was live-tested — then `urb-agents#1997`
retired it in favor of an ephemeral k3s-pod runner instead, reusing the already-shipped Rancher
Desktop `uis deploy forgejo-runner` service ("k3s is k3s," one implementation, both platform
targets) rather than Proxmox-specific VM IaC. See `platforms/proxmox/STRUCTURE.md`'s "nas's
history in this platform" note for the full timeline. F1-F3 and the open questions below were
real findings at the time and are kept for history, not because the VM path they describe is
still the current answer.

**Goal**: Give UIS's Forgejo install (`PLAN-system-forgejo-core-service.md`) a real,
registered Forgejo Actions runner on a dedicated Proxmox VM — the half of Terje's
2026-10-13→10-19 CI decision that was never implemented. Scope this properly before writing
any code: two of the open questions below were explicitly flagged as undecided in the
handoff that named the decision, not something this document can resolve by guessing.

**Related**: [PLAN-system-forgejo-core-service.md](./PLAN-system-forgejo-core-service.md)
(the git host this runner attaches to — done, merged, not yet live-tested),
[INVESTIGATE-service-epinio-deploy-path.md](../backlog/INVESTIGATE-service-epinio-deploy-path.md)
(records the same decision independently, see "What this is NOT" below),
`urb-agents#1910` (the authoritative decision record)

**Created**: 2026-10-21

---

## Background — this was missed, not deferred

`urb-agents#1910`'s requirement handoff is explicit and marked "not open for
re-litigation":

> Git host: Forgejo. **CI: official Forgejo Runner on a dedicated Proxmox VM (not LXC).**

`INVESTIGATE-service-epinio-deploy-path.md` (written independently, before Forgejo was
named explicitly) records the same requirement in its own "what is already decided" list:

> Git host: a self-hosted git forge, with its own CI runner on dedicated infrastructure
> (not a container), and its own OCI registry for what gets built.

`PLAN-system-forgejo-core-service.md` built the git host and its built-in OCI registry —
provisioned as an LXC guest through the existing `CORE_SERVICES` mechanism, same shape as
registry/bao/garage. It does not mention a runner anywhere. That PLAN's own scope section
("What this plan does NOT do") lists three deliberate follow-ups (CORE_SERVICES
integration, `FORGEJO_IP` capture, containerd trust) — the runner is not among them. This
was a genuine miss, caught only when asked directly, not a scope cut flagged at the time.

## What this is NOT

**Not a blocker for Epinio's own deploy path.** `epinio push --git` builds from source
using Epinio's own internal buildpacks pipeline (Tekton/kpack-style, inside the Epinio
namespace) — it does not invoke Forgejo Actions at all. The runner is a separate,
general-purpose CI capability Terje decided UIS needs (running tests/builds/linting
against any Forgejo-hosted repo, GitHub-Actions-workalike), not a dependency of
`PLAN-service-epinio-00[1-3]`. Scoping and building it does not block or get blocked by
those PLANs — tracked as its own line item for exactly that reason.

---

## Part 1: What already exists that this can build on

### F1 — `vm-ensure.yml` is already a generic, non-k3s-specific VM primitive

`platforms/proxmox/ansible/playbooks/vm-ensure.yml` ("create a Proxmox VM from a
DECLARATION, via cloud-init") only reads `vm.name`, `vm.vmid`, `vm.memory`, `vm.cores`,
`vm.storage`, `vm.disk_gb`, `vm.ip`, `vm.ciuser` — no k3s-specific field anywhere in the
playbook itself. The k3s-specific fields a k3s node's declaration *also* carries
(`k3s_role`, `server_url`, `taint`, `cluster_cidr`, `service_cidr`) are consumed by the
separate `k3s-ensure.yml` playbook, not this one. **This means the "dedicated VM, not LXC"
requirement already has a working, proven primitive to provision through** — the runner
does not need `k3s-ensure.yml` at all (it never joins the cluster as a node), just a
declaration file read by `vm-ensure.yml` directly, the same way `03-k3s-apply.sh` calls it
per k3s node today (`ap playbooks/vm-ensure.yml -e "vm_file=generated/vars/vms/<name>.yml"`).

**Implication**: `generate-ansible-config.sh`'s existing `write_vm_decl()` is NOT reusable
as-is — its signature is hardwired to k3s fields (`k3s_role`, `server_url`, `taint`,
`cluster_cidr`, `service_cidr`) that mean nothing for a standalone runner VM. A new,
simpler declaration writer (or a hand-written vars file, if this never needs to be
regenerated per-install the way k3s nodes are) is the right shape — not a forced fit into
the k3s writer.

### F2 — the registration token needs an admin account that doesn't exist yet

`PLAN-system-forgejo-core-service.md` Phase 3.1 ("Operator creates the first admin account
and organisation by hand") is explicitly manual and not automated, by design — same as
every other core-services guest's bootstrap credential. Forgejo's own runner-registration
token (`forgejo-cli actions generate-runner-token`, or the Instance Admin → Actions →
Runners UI, or `POST /api/v1/admin/actions/runners/registration-token` with an admin API
token) requires that admin account to exist first. **This runner cannot be fully
automated end-to-end without resolving how it gets a registration token** — either the
admin-bootstrap step happens first (same operator-does-this-once precedent as Phase 3.1),
or runner registration itself becomes a second manual step. Worth deciding which, not
assuming either.

*(The exact registration CLI/API shape above is per Forgejo's own published Actions admin
documentation, not independently verified against the pinned Forgejo version in this repo
— confirm against `forgejo-runner --help` and the admin API for whatever version is
actually running before writing the role.)*

### F3 — the git host's own image-pinning discipline should carry over

`roles/forgejo/defaults/main.yml` pins Forgejo itself by digest (`forgejo_image:
"codeberg.org/forgejo/forgejo@sha256:..."`), verified live against Codeberg's own v2
registry API rather than left as a floating tag. The runner (`code.forgejo.org/forgejo/runner`
or the standalone `forgejo-runner` binary — same project either way) should get the same
treatment: a version/digest pinned and independently re-verified, not copied from memory.

---

## Part 2: Proposed plans (ordered)

```
PLAN-system-forgejo-runner-001-provision-vm.md    ← not written yet
PLAN-system-forgejo-runner-002-install-register.md ← not written yet
```

### PLAN-001 — Provision the dedicated VM

Add a VM declaration (new writer, not `write_vm_decl` — see F1) and a call to
`vm-ensure.yml`, parallel to how `03-k3s-apply.sh` does it for k3s nodes but outside the
`CORE_SERVICES`/LXC mechanism entirely. Decide sizing (cores/memory/disk — a build VM
needs more disk than any current core-services guest, which top out around the registry
cache's 60 GB) and Proxmox host placement (same host as Forgejo for lowest latency to
push/pull, or a different host to isolate build load from git-host availability — open
question 3 below).

*Acceptance*: a running VM, reachable from the Forgejo guest, surviving host reboot — same
acceptance bar as every other provisioned guest in this repository.

### PLAN-002 — Install, configure and register the runner

Docker (or whatever execution backend open question 1 resolves to), the pinned
`forgejo-runner` binary/image, registration against the Forgejo instance (gated on F2),
systemd-wrapped per this repository's own convention (`roles/forgejo/`, `roles/garage/`
both do this).

*Acceptance*: a real Forgejo Actions workflow file in a real repository on this install
runs to completion on this runner — the same "proven live, not claimed" bar every other
service in this repository holds itself to.

---

## Part 3: Open questions — explicitly not decided, not this document's call

1. **Docker-in-Docker vs skopeo for pushing built images.** Verbatim from `urb-agents#1910`'s
   own "explicitly NOT decided or verified yet" list — still open. DinD gives a workflow
   author the familiar `docker build && docker push` they'd use anywhere; skopeo (or
   buildah/kaniko) avoids a privileged DinD container on a box that runs arbitrary
   contributor-submitted workflow code. This is a security-posture call, not an
   implementation detail — needs Terje or whoever owns the security review, not a default
   picked here.
2. **Network isolation between the runner and platform workloads.** Also verbatim from
   `#1910`: "UIS has no NetworkPolicy and builds run user code beside platform workloads."
   At the VM level (not applicable to in-cluster NetworkPolicy, since this is a standalone
   VM, not a pod) this becomes: what can the runner's VM reach by firewall — Forgejo
   (git + registry) certainly, but should it reach other core-services guests (postgres,
   bao, garage) at all? The other host-level guests' own nftables rules
   (`roles/garage/templates/*-nftables.conf.j2`, `roles/forgejo/templates/forgejo-
   nftables.conf.j2`) are each scoped to what that guest itself needs to expose — the
   runner's equivalent rule needs its own deliberate answer, not a copy of an unrelated
   guest's rule.
3. **One runner VM, or a pool?** A single always-on runner is simplest and matches "a
   dedicated Proxmox VM" (singular) in the decision as recorded. Whether that's meant to
   stay singular as usage grows, or whether `#1910`'s phrasing just hadn't considered scale
   yet, is unasked.
4. **Registration-token handling.** F2 above — whether runner registration is folded into
   the existing manual admin-bootstrap step (Phase 3.1) or stays a second, separate manual
   step, and whether the resulting runner token goes through UIS's own secrets pipeline
   (`00-master-secrets.yml.template`) or stays host-local the way other guests' bootstrap
   credentials already do.
5. **Runner labels / workflow-file compatibility.** Forgejo Actions workflow files
   (`.forgejo/workflows/*.yml`) target runners by label (`runs-on: docker` etc.) — what
   labels this runner registers under is a contract with whoever writes workflow files
   against it later, worth deciding once, not per-workflow.

---

## Honest limits of what's in this document

No code has been written for this. F1-F3 above are read from this repository's existing,
merged code (`vm-ensure.yml`, `k3s-ensure.yml`, `roles/forgejo/defaults/main.yml`,
`PLAN-system-forgejo-core-service.md`) — not guessed. The Forgejo Actions registration
mechanism described in F2 is from Forgejo's own public documentation, not independently
verified against the exact pinned version in this repo, and is flagged as such. Nothing
here has run against a live Proxmox cluster, because none exists in this working
environment — same caveat as every other platforms/proxmox document in this repository.
