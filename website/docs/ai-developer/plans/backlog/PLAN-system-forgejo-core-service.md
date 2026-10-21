# Plan: Forgejo as a platforms/proxmox core service

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog — Phases 1 and 2 code written, not yet run against a live Proxmox cluster

**Goal**: Add Forgejo (self-hosted git host + its own built-in OCI registry) as a new
`platforms/proxmox` core service — the same host-level-guest shape as the registry cache,
Bao and Garage — so the Epinio self-service deploy path
([INVESTIGATE-service-epinio-deploy-path.md](./INVESTIGATE-service-epinio-deploy-path.md))
has somewhere to push built images to and pull them back from.

**Investigation**: [INVESTIGATE-service-epinio-deploy-path.md](./INVESTIGATE-service-epinio-deploy-path.md),
[INVESTIGATE-system-registry-cache.md](./INVESTIGATE-system-registry-cache.md) (Parts 4-5, the
containerd-trust gap this plan does **not** close — see "What this plan does not do" below)

**Related**: `urb-agents#1909`, `#1910`, `#1912`, `#1913`, `#1917` — Terje's 2026-10-20 decision
that this should move into UIS proper now, ahead of the "eventual, deliberate handover" timing
`#1914` had originally described.

**Last Updated**: 2026-10-20

---

## Problem Summary

The Epinio PoC proved Forgejo works for this purpose, but built it as one-off IaC in a private
platform repository outside UIS, with a hand-written guest declaration (static IP, a specific
Proxmox host and VMID) rather than through `platforms/proxmox`'s own generic `CORE_SERVICES`
mechanism that every other core-services guest (registry cache, Bao, Garage, Postgres) already
uses. This plan brings Forgejo into that same generic mechanism, translating the proven
install/config logic rather than copying the one-off version verbatim.

## What this plan does

1. **`platforms/proxmox/ansible/roles/forgejo/`** — a new role, structured identically to
   `roles/garage` (Docker-based, systemd-wrapped, nftables-gated): `defaults/main.yml`,
   `handlers/main.yml`, `tasks/main.yml`, and three templates (`app.ini.j2`,
   `forgejo-nftables.conf.j2`, `forgejo.service.j2`). Pins the image **by digest**, verified live
   against Codeberg's own v2 registry API (see the role's own defaults file for the exact query
   and result) rather than left as a tag the way the original PoC IaC did — the one place this
   plan improves on what it's translating.
2. **`platforms/proxmox/ansible/playbooks/service-forgejo.yml`** — the per-guest install
   playbook, following the `service-garage.yml`/`service-bao.yml` shape exactly. Resolves its own
   domain from the connection address at play time (`ansible_host`), so no extra `-e` flag or
   hardcoded address is ever needed — this repository's standing rule against baking real
   addresses into anything committed.
3. **`website/docs/production/forgejo.md`** — a docs page following the registry-cache page's
   precedent (host-level-guest services get documented under `production/`, not
   `services/management/`, since they aren't `uis deploy <service>` Kubernetes workloads).

## What this plan does NOT do — integration is a separate, deliberate step

> **Update 2026-10-20**: items 1-3 below are now done — see Phase 2's checklist. Left as
> written for the historical record of what was deferred and why; item 4 (admin account)
> remains genuinely out of scope.

Three things remain for whoever integrates this (not done here, because they touch
multi-service shared files this plan's own code review should see as a clean, reviewable
diff rather than entangled with new-role additions):

1. **`generate-ansible-config.sh`** needs one new `case` arm in its `for svc in $CORE_SERVICES`
   loop (alongside `pg`/`bao`/`garage`/`registry`), e.g.:
   ```bash
   forgejo)  write_core_service forgejo 410 2 2048 512 "order=3" "nesting=1,keyctl=1" 8 /var/lib/forgejo 50 "" forgejo ;;
   ```
   VMID **410** is the next free slot after the existing `405`-`409` (verified by reading the
   existing case statement directly, not guessed) — **not** the real PoC's VMID 411 on its real
   host, which was assigned ad hoc outside this generic mechanism and has no bearing on what a
   fresh install through `CORE_SERVICES` should use.
2. **`05-core-services-apply.sh`** needs a `FORGEJO_IP` capture (identical shape to the existing
   `REGISTRY_IP`/`BAO_IP` capture in its per-service loop) so a later step can wire containerd
   trust for Forgejo's registry — see item 3.
3. **Containerd trust for Forgejo's own registry** is explicitly out of scope here — that is
   [INVESTIGATE-system-registry-cache.md Parts 4 and 5](./INVESTIGATE-system-registry-cache.md#part-4--forgejoepinio-needs-a-different-shape-not-another-upstream-2026-10-19),
   a structurally different mechanism from the one this plan's role provides, tracked and
   (as of this writing) being implemented as its own parallel change. **A cluster cannot actually
   pull from this Forgejo install until that lands too** — this plan alone does not make Forgejo
   usable end-to-end.
4. **Admin account / first repository** — deliberately not automated (see the role's own
   comment) — an explicit operator step after install, same as every other core-services guest
   with a bootstrap credential.
5. **The CI runner `urb-agents#1910` actually asked for** — "official Forgejo Runner on a
   dedicated Proxmox VM (not LXC)" was part of the same decision this plan implements, and
   was missed entirely here (caught 2026-10-21, not flagged as deferred at the time this plan
   was written). Tracked separately now:
   [INVESTIGATE-system-forgejo-runner.md](./INVESTIGATE-system-forgejo-runner.md). Not a
   blocker for this plan's own Phase 3 (a real `git push`/registry pull doesn't need the
   runner), but a real gap against what was actually decided.

## Honest limits of what's been verified

- **No live Proxmox cluster exists in this working environment.** Every file here has been
  YAML-parsed, `ansible-playbook --syntax-check`-ed, and (for the three Jinja templates)
  rendered with representative dummy variables to catch template errors — none of that proves
  the role actually installs and runs Forgejo on a real guest. **This needs imac.**
- The image digest was independently verified live against `codeberg.org/v2/...` on 2026-10-20 —
  that part is a real, reproducible check, not copied from the PoC's own comment (though it
  happens to match).
- The `0777` data-directory permission, the SQLite backing store, and the "no admin bootstrap"
  choice are carried over from the proven PoC reference as-is — not independently re-derived or
  re-justified here, since they already have a working precedent to translate from.
- VMID 410 and the `write_core_service` call signature in "What this plan does NOT do" above are
  **not yet applied anywhere** — they are the exact diff for whoever does that integration step,
  written out so it doesn't need re-deriving, not a claim that the file has already been changed.

## Phase 1: Role and playbook review

### Tasks

- [x] 1.1 `roles/forgejo/` written, translated from the proven PoC reference, digest-pinned
- [x] 1.2 `service-forgejo.yml` written, resolves its own domain at play time
- [x] 1.3 `website/docs/production/forgejo.md` written
- [ ] 1.4 Code review of this plan and its diff

### Validation

User (or a reviewing maintainer) confirms the role matches house conventions before it moves
toward integration.

---

## Phase 2: Integration into CORE_SERVICES

### Tasks

- [x] 2.1 Add the `forgejo)` case to `generate-ansible-config.sh` — done 2026-10-20, VMID
      410 as planned, `order=6` (not `order=3` as first sketched — that collided with
      garage's own `order=3`)
- [x] 2.2 Add `FORGEJO_IP` capture to `05-core-services-apply.sh`'s per-service loop — done
- [x] 2.3 Coordinate with the registry-direct-insecure-trust change — done: the "wire k3s
      registry trust" step is now ONE combined `ansible-playbook` invocation passing
      `registry_host` (if `registry` selected) and `registry_direct_insecure` (if `forgejo`
      selected) together, reading Forgejo's registry port from `roles/forgejo/defaults/
      main.yml`'s `forgejo_http_port` rather than duplicating it

### Validation

A lab owner who adds `forgejo` to `CORE_SERVICES` and runs `05-core-services-apply.sh` gets a
running, HA-registered, firewalled Forgejo guest — **tested by imac**, not claimed here. The
code for Phase 2 is written and `bash -n`/`shellcheck`-clean, but like Phase 1, has not run
against a live Proxmox cluster.

---

## Phase 3: First real use

### Tasks

- [ ] 3.1 Operator creates the first admin account and organisation by hand
- [ ] 3.2 Confirm a real `git push` and a real `docker push`/`pull` against the built-in registry
      work end to end, once Phase 2's registry-trust wiring also lands

### Validation

A real repository pushed to this Forgejo install, and a real image pulled from its registry by
a k3s node — both proven live, the same acceptance-test discipline every other core service in
this repository already holds itself to.
