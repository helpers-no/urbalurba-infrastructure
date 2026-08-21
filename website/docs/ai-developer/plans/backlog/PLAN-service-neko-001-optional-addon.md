# Ship neko as an optional add-on — the honest case for and against

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog — ✅ APPROVED to plan 2026-08-21; **browserless ships first**

**Terje approved** (2026-08-21): neko is planned as a service. Sequencing is
explicit — [browserless-001](./PLAN-service-browserless-001-deploy.md) ships
first, and creates the `AUTOMATION` category this plan depends on.

The case against in Part 1 stands as recorded — it was argued honestly and the
decision went the other way, which is the point of writing it down. What it now
governs is not *whether* neko ships but *how*: opt-in only, in no stack, security
model in the deploy output.

**Prerequisite**: [PLAN-service-browserless-001-deploy](./PLAN-service-browserless-001-deploy.md)
must ship first — it opens the `AUTOMATION` category this service lives in.

**Handoff**: `ai-developer/for-uis-maintainer-browser-service.md` (home repo).
ops asked for neko to be argued **both ways** before deciding. That is Part 1 of
this plan, and it is the part worth reading.

**Proposal**: name `neko` (upstream), category `AUTOMATION`, manifests 410–419,
priority `95`, **shipped but never in a default profile** — explicit opt-in only.

**Last Updated**: 2026-08-21

**Priority**: Low — sequenced after browserless, not a judgement on its value.

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

### Recommendation — and what Terje decided

**Ship it, but not bundled and not by default.** Approved 2026-08-21, with
browserless first. Specifically:

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

*(Written before the decision: "if Terje declines this plan, browserless is
unaffected — that is why they are separate." He did not decline; the split still
did its job, by making the sequencing decidable separately from the scope one.)*

---

## Phase 1: Service definition, gated

⚠️ **Rewritten 2026-08-21** against `adding-a-service.md` and the contributor
rules docs, after the first draft was written from inference. See the browserless
plan's Implementation Notes for what that cost.

**Prerequisite**: the `AUTOMATION` category exists (browserless-001 Phase 1).
This plan adds no category work.

### Tasks

- [ ] 1.1 **Step 2** — `provision-host/uis/services/automation/service-neko.sh`:
      `SCRIPT_CATEGORY="AUTOMATION"`, `SCRIPT_NAMESPACE="browser"`,
      `SCRIPT_PRIORITY="95"`, `SCRIPT_PLAYBOOK="410-setup-neko.yml"`,
      `SCRIPT_REMOVE_PLAYBOOK="410-remove-neko.yml"`, `SCRIPT_CHECK_COMMAND`,
      `SCRIPT_LOGO="neko-logo.svg"`. **Pinned image tag — no `v` prefix** (trap 4).
      Metadata carries no logic
- [ ] 1.2 **Step 3** — `manifests/410-neko-deployment.yaml`, from
      `platform/browser/neko.yaml` (home repo). Not `-config` (no Helm chart);
      not a StatefulSet — it is a Deployment with `strategy: Recreate` plus a PVC
- [ ] 1.3 **Step 4** — `manifests/410-neko-ingressroute.yaml`, same number as the
      playbook, per `architecture/manifests.md`. See Phase 3 — the WebRTC half
      does **not** ride this
- [ ] 1.4 **Step 5/6** — setup and remove playbooks following
      `rules/provisioning.md`: `_target`, two-stage readiness, retry-based
      progress feedback, no `.localhost` testing from Ansible
- [ ] 1.5 **Step 7 — secrets, per `rules/secrets-management.md`**: secret name
      **`urbalurba-secrets`** in namespace `browser`; `NEKO_USER_PASSWORD` and
      `NEKO_ADMIN_PASSWORD` defined once in `00-common-values.env.template` and
      referenced as `${...}` from `00-master-secrets.yml.template`; pod reads
      `secretKeyRef` only; LocalDev defaults keep Rancher Desktop zero-config.
      ⚠️ **These are real login credentials for a browser that holds live
      sessions** — a shipped default that is also a working password is not
      acceptable here even by the usual standard
- [ ] 1.6 **Step 9** — commented-out entry in
      `provision-host/uis/templates/uis.extend/enabled-services.conf.default`,
      with the security warning as the adjacent comment
- [ ] 1.7 **Step 10 — this is the gating mechanism, and it is concrete**:
      `provision-host/uis/lib/stacks.sh`. neko is added to **no stack**. There is
      no `automation` stack and this plan does not create one. `uis stack install`
      can therefore never bring neko up; only explicit `uis deploy neko` can
- [ ] 1.8 Deploy output states the security model in full — private-network-only,
      **unauthenticated CDP**, PVC-not-backed-up, single-writer. Printed, not linked

### Validation

```bash
./uis stack list                  # no stack contains neko
./uis deploy                      # enabled-services only; neko absent
./uis deploy neko                 # the only path that starts it
```

---

## Phase 2: Carry the solved traps across verbatim

Documented in `platform/browser/neko.yaml` (home repo). Each is invisible when
wrong, which is why they are tasks rather than notes. **Copy from ops' file; do
not reconstruct from this summary** — the same rule that governed the
endpoint-manager copy-back.

### Tasks

- [ ] 2.1 Chromium policy `DeveloperToolsAvailability: 2` → **`1`**, that key
      only, keeping upstream's other hardening. Without it
      `Target.attachToTarget` is silently refused and no agent control works
- [ ] 2.2 socat sidecar re-exposing localhost-bound CDP as pod `:9222`
- [ ] 2.3 Health endpoint is `/health` — `/api/health` returns 404
- [ ] 2.4 Profile PVC: `strategy: Recreate` (single-writer), `fsGroup: 1000`,
      `local-path` storage class
- [ ] 2.5 PVC **explicitly excluded from backup**, with the reason recorded next
      to the exclusion: it is a live credential store, and a backup is a second
      copy of the blast radius. Coordinate with
      [INVESTIGATE-system-backup-and-scheduling](./INVESTIGATE-system-backup-and-scheduling.md)
      so the exclusion is not silently reversed later

### Validation

A human reaches the web view and logs in; an agent drives the same session over
CDP; the login survives a pod restart.

---

## Phase 3: Exposure per environment, verify, and documentation

### Tasks

- [ ] 3.1 ⚠️ **WebRTC media does not ride an HTTP IngressRoute.** It needs raw
      TCP (TCP-mux + NAT1TO1). Rancher Desktop: a localhost port. Proxmox: the
      reference installation's tailnet LB manifest, as the documented example.
      Cloud: **explicitly out of scope**, stated not inferred. The exposure layer
      differs per environment; the pod does not
- [ ] 3.2 Verify playbook `ansible/playbooks/410-test-neko.yml`, registered in
      **all three** places (see browserless-001 Phase 3): `VERIFY_SERVICES`, the
      `cmd_verify()` case, and the hardcoded usage list
- [ ] 3.3 Avoid the `kubectl run --rm -i` stdout idiom from `rules/provisioning.md`
      — see browserless-001 task 3.5
- [ ] 3.4 **Step 11** — `website/docs/services/automation/neko.md`, added to
      `website/sidebars.ts`; security model carried verbatim from
      `platform/browser/README.md` including the password-typing usage rule;
      `website/static/img/services/neko-logo.svg` (+ `src/` variant)
- [ ] 3.5 MCP registration recipe (`claude mcp add`, `--cdp-endpoint`)
- [ ] 3.6 State the two-browser rule where users will hit it: *many blank
      browsers in parallel → browserless; one logged-in browser, shared → neko*
- [ ] 3.7 Build the docs in the Node container and **read the warnings, not the
      exit code** — broken links warn and still exit 0

### Validation

Docs build with no new broken-link warnings. `uis verify` lists neko. A reader
can tell which of the two services they need without asking.

---

## Acceptance Criteria

- [ ] Terje has approved shipping neko at all, and the opt-in-only gating
      — ✅ **approved 2026-08-21**, sequenced after browserless
- [ ] browserless-001 has shipped and the `AUTOMATION` category exists
- [ ] It meets the laptop requirement: `uis deploy neko` on Rancher Desktop,
      nothing else. (It does — the objection in Part 1 is about *purpose*, not
      deployability. `adding-a-service.md` asks that this be stated in the plan
      rather than discovered, so it is stated here.)
- [ ] neko belongs to no stack, and `uis deploy` with no argument does not start it
- [ ] The verify playbook is registered in **all three** places
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

**The Case-2 auth gap is now answered rather than documented as a limitation** —
that was the fallback had this plan been declined. It was not.

---

## Files to Modify

**Service**
- `provision-host/uis/services/automation/service-neko.sh` (new)
- `manifests/410-neko-deployment.yaml` (new — from `platform/browser/neko.yaml`)
- `manifests/410-neko-ingressroute.yaml` (new — HTTP only; WebRTC is separate)
- `ansible/playbooks/410-setup-neko.yml`, `410-remove-neko.yml` (new)
- `provision-host/uis/templates/secrets-templates/00-common-values.env.template`
  — `NEKO_USER_PASSWORD`, `NEKO_ADMIN_PASSWORD`
- `provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template`
  — `urbalurba-secrets` in namespace `browser`
- `provision-host/uis/templates/uis.extend/enabled-services.conf.default`
- `provision-host/uis/lib/stacks.sh` — **no change, deliberately** (task 1.7)

**Verify**
- `ansible/playbooks/410-test-neko.yml` (new)
- `provision-host/uis/lib/integration-testing.sh` — `VERIFY_SERVICES`
- `provision-host/uis/manage/uis-cli.sh` — `cmd_verify()` dispatch **and** its
  hardcoded usage list

**Docs**
- `website/docs/services/automation/neko.md` (new)
- `website/sidebars.ts`
- `website/static/img/services/neko-logo.svg` (+ `src/` variant) (new)

**No category work** — browserless-001 Phase 1 owns that.
