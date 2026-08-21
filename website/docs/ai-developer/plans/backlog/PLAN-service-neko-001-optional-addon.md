# Ship neko as an optional add-on — the honest case for and against

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog — ⚠️ AWAITING TERJE'S APPROVAL, and this one is a genuine judgement call

**Prerequisite**: [PLAN-service-browserless-001-deploy](./PLAN-service-browserless-001-deploy.md)
must ship first — it opens the `AUTOMATION` category this service lives in.

**Handoff**: `ai-developer/for-uis-maintainer-browser-service.md` (home repo).
ops asked for neko to be argued **both ways** before deciding. That is Part 1 of
this plan, and it is the part worth reading.

**Proposal**: name `neko` (upstream), category `AUTOMATION`, manifests 410–419,
priority `95`, **shipped but never in a default profile** — explicit opt-in only.

**Last Updated**: 2026-08-21

**Priority**: Low — deliberately. See Part 1.

---

## Part 1: The second-user test, argued both ways

browserless passed on a concrete unmet dependency in a service UIS already ships.
neko has no such argument, and pretending otherwise would be the mistake the
[endpoint-manager verdict](./INVESTIGATE-system-roaming-dependency-addresses.md)
was written to prevent.

### The case FOR

- **The Case-2 auth model is genuinely general.** "A human logs in by hand, then
  agents drive the same session" is the only workable answer for anything behind
  2FA or an SSO flow an agent cannot complete. UIS ships several such UIs itself
  (Authentik, ArgoCD, Grafana, Backstage).
- **Authoring browser checks.** Watching a real browser drive an in-cluster
  service, then capturing that flow as an Uptime Kuma monitor, is a plausible dev
  loop — and it pairs with browserless rather than competing.
- **Identical interface, topology may differ.** A watchable browser in-cluster
  behaves the same on a laptop and a server, which is UIS's core promise.

### The case AGAINST — stronger, in my judgement

- **On Rancher Desktop the value evaporates.** neko solves *"the human is not
  where the cluster is."* On a laptop the human **is** where the cluster is, with
  a real browser already open and already logged in. UIS's baseline environment
  is precisely the one where neko has least reason to exist. It passes the
  technical Rancher Desktop test — it runs — and fails the *purpose* test.
- **It is a shared mutable singleton holding live credentials.** ONE session,
  `strategy: Recreate`, single-writer, no horizontal scale. That is an unusual
  shape for a product service, and every user has to be taught it.
- **Its blast radius is larger than browserless's and differently shaped.** CDP
  on neko is **unauthenticated full control including cookies of a logged-in
  human**. browserless has a token; neko's control channel does not. Shipping
  this as a `uis deploy` target means shipping a footgun that is only safe given
  a correct exposure layer — and the exposure layer differs per environment,
  which is exactly where mistakes happen.
- **The PVC is deliberately not backed up**, because it is a live credential
  store and a backup is a second copy of the blast radius. Correct, and a caveat
  that must be re-explained to every user forever.

### Recommendation

**Ship it, but not bundled and not by default.** Specifically:

- a separate service, separately approvable (this plan)
- **never in a default or "everything" profile** — see
  [INVESTIGATE-cli-stack-profiles](./INVESTIGATE-cli-stack-profiles.md)
- deploy prints the security model, not a link to it
- documented as the **third rung** of the tool-choice ladder, reached only when
  rungs 1 and 2 fail

The reason to ship rather than decline: the Case-2 auth problem is real and UIS
has no other answer to it. The reason to gate it hard: nothing above establishes
that a second installation *wants* it, and the failure mode of guessing wrong is
a credential-bearing browser exposed on a network someone assumed was private.

**If Terje declines this plan, browserless is unaffected** — that is why they are
separate.

---

## Phase 1: Service definition, gated

### Tasks

- [ ] 1.1 `provision-host/uis/services/automation/service-neko.sh` —
      `SCRIPT_CATEGORY="AUTOMATION"`, `SCRIPT_NAMESPACE="browser"`,
      `SCRIPT_PRIORITY="95"`, pinned image tag (**no `v` prefix** — see traps)
- [ ] 1.2 Excluded from every default/bundle profile; deploy only on explicit
      `uis deploy neko`
- [ ] 1.3 Passwords (user + admin) from `urbalurba-secrets` via `secretKeyRef`;
      LocalDev defaults so Rancher Desktop is zero-config
- [ ] 1.4 Deploy output states the security model in full — private-network-only,
      unauthenticated CDP, PVC-not-backed-up, single-writer

### Validation

`uis deploy` of any profile does **not** bring up neko. `uis deploy neko` does.

---

## Phase 2: Carry the solved traps across verbatim

These are documented in `platform/browser/neko.yaml` (home repo) and must not be
rediscovered. Each one is invisible when wrong.

### Tasks

- [ ] 2.1 Chromium policy `DeveloperToolsAvailability: 2` → **`1`**, that key
      only, keeping upstream's other hardening. Without it
      `Target.attachToTarget` is silently refused and no agent control works
- [ ] 2.2 socat sidecar re-exposing localhost-bound CDP as pod `:9222`
- [ ] 2.3 WebRTC needs raw TCP (TCP-mux + NAT1TO1) and does **not** ride an HTTP
      ingress — the exposure layer differs per environment, the pod does not
- [ ] 2.4 Health endpoint is `/health` (`/api/health` 404s)
- [ ] 2.5 Profile PVC: `strategy: Recreate`, `fsGroup: 1000`, `local-path` class,
      explicitly excluded from backup with the reason recorded

### Validation

A human reaches the web view and logs in; an agent drives the same session over
CDP; the login survives a pod restart.

---

## Phase 3: Exposure per environment, and docs

### Tasks

- [ ] 3.1 Rancher Desktop: localhost only. Proxmox: the reference installation's
      tailnet LB manifest as the documented example. Cloud: **explicitly out of
      scope** — say so rather than leaving it to inference
- [ ] 3.2 Service docs page carrying the security model verbatim from
      `platform/browser/README.md`, including the password-typing usage rule
- [ ] 3.3 MCP registration recipe (`claude mcp add`, `--cdp-endpoint`)
- [ ] 3.4 The two-browser rule stated where users will actually hit it: *many
      blank browsers in parallel → browserless; one logged-in browser, shared →
      neko*

### Validation

Docs build. A reader can tell which of the two services they need without asking.

---

## Acceptance Criteria

- [ ] Terje has approved shipping neko at all, and the opt-in-only gating
- [ ] neko never appears in a default profile
- [ ] Agent control works — i.e. the `DeveloperToolsAvailability` override is in
      place and proven, not assumed
- [ ] Login survives a pod restart
- [ ] The security model is in the deploy output, not only the docs
- [ ] The PVC is excluded from backup, with the reason recorded next to the
      exclusion
- [ ] Nothing on the reference installation changed as a side effect

---

## Implementation Notes

**Priority `95` is a statement, not an accident.** It puts neko with the
optional tooling (pgadmin, redisinsight, jupyterhub), after everything a working
platform needs.

**The name.** Upstream is `neko`, and UIS convention is upstream product names
(grafana, authentik, uptime-kuma, litellm). Keeping it. Worth noting the one
weakness: `neko` is a common word and says nothing about what the service does —
but inventing a name would break a convention that has held for all 34 existing
services, and the category description carries the meaning.

**If this plan is declined**, the Case-2 auth gap should be written down as a
known UIS limitation rather than left silent. Users will hit it; better they meet
a documented boundary than a puzzle.

---

## Files to Modify

- `provision-host/uis/services/automation/service-neko.sh` (new)
- `manifests/410-neko-config.yaml` (new — from `platform/browser/neko.yaml`)
- `ansible/playbooks/410-setup-neko.yml`, `410-remove-neko.yml` (new)
- `provision-host/uis/templates/secrets-templates/` — user + admin passwords
- `00-common-values` — LocalDev defaults
- `website/docs/services/automation/neko.md` (new)
