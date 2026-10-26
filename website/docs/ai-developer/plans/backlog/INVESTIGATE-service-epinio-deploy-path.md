# Investigate: Epinio Deploy Path for UIS

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog — PLAN-001 (install) shipped and verified; PLAN-002/003 not started

**Goal**: Decide how UIS itself (CLI surface, service layout, docs) should incorporate
an Epinio-based self-service deploy path — "push code, get a URL and status back, read
logs with no kubeconfig" — alongside the existing ArgoCD path, once the proof-of-concept
below has cleared its gates.

**Priority**: Low until the gates below report back. This file exists so the decision
isn't re-derived from scratch when they do.

**Last Updated**: 2026-10-20

**Related**:
- [Rules for Deploying Applications](../../../contributors/rules/application-deployment.md) —
  the 2026-09-07 `uis provisions / ArgoCD deploys` rule this proposal takes an explicit
  exception to, **approved by Terje** (`urb-agents#1915`)
- [INVESTIGATE-service-argocd-dct-deploy.md](./INVESTIGATE-service-argocd-dct-deploy.md) —
  prior art for a "push and get a URL back" developer experience, built on the ArgoCD path
- `urb-agents#1909` — the platform evaluation (Kubero/KubeVela/Devtron/Epinio) and the
  product requirement behind this
- `urb-agents#1910` — the handoff that scoped this document to "how UIS builds it,"
  separating it from the production-rollout decision, which is tracked elsewhere
- `urb-agents#1917` — full handoff once the lab PoC's identity gates passed (below)

---

## Scope of this document, and what it deliberately does not cover

This document is the **UIS-side implementation question only**: once Epinio is proven
to work for this platform's constraints, what does adding it to this repository look
like — CLI surface, numbering, docs, and how it relates to the existing ArgoCD path.

It does **not** re-litigate:
- **That Epinio is the chosen platform.** That evaluation already happened upstream of
  this file.
- **Whether the proof-of-concept gates pass.** That is lab work against a non-production
  cluster, run by whoever owns that lab, not armchair-decided here.
- **Production rollout.** Explicitly a separate decision, tracked on its own issue.

## What is already decided, and is not open for re-litigation here

- Git host: a self-hosted git forge, with its own CI runner on dedicated infrastructure
  (not a container), and its own OCI registry for what gets built. The existing
  pull-through registry cache keeps that separate role.
- Identity: Epinio's bundled Dex must work against this platform's two existing OIDC
  identity providers via generic OIDC — not a vendor-specific integration for either.
- Object storage: the platform's existing S3-compatible object store, already in use
  elsewhere in UIS.
- One Epinio namespace per team. Per-app database service for now. Kubernetes Secrets
  for now (the platform has a secrets-manager service installed, but nothing in UIS
  uses it as a backing store yet — see the `requires:`/secrets gap already tracked in
  [application-deployment.md](../../../contributors/rules/application-deployment.md)).

## What is explicitly NOT decided or verified yet — real open risks, assumed away by no one

These are proof-of-concept gates, not implementation details to paper over:

- ~~**Biggest risk**: how Epinio maps OIDC claims/groups to namespace roles. Untested.~~
  **Resolved 2026-10-20 — see "Identity gates passed" below.**
- ~~Epinio's bundled Dex against either of this platform's identity providers: untested
  in both directions.~~ **Resolved — both proven, plus a third provider.**
- `epinio push --git` against a self-hosted (non-GitHub/GitLab) git forge: should work
  per Epinio's source (it's a plain git clone), but the auto-deploy webhook is
  GitHub/GitLab-only and isn't needed for this platform's CI-triggered flow.
- Whether Epinio can pull from the forge's own registry with credentials. **Containerd
  trust for that registry (plain HTTP, no TLS) is a separate, now-filed gap** — see
  [INVESTIGATE-system-registry-cache.md, Part 4](./INVESTIGATE-system-registry-cache.md#part-4--forgejoepinio-needs-a-different-shape-not-another-upstream-2026-10-19)
  (`urb-agents#1912`): it is not another entry behind the existing pull-through cache,
  and whatever provisions the forge must not independently clobber the cache's own
  `registries.yaml` wiring.
- The object store as Epinio's S3 backend: **the concept is proven** (ops's own PoC
  harness, `urb-agents#2019`, 2026-10-26) **but the real UIS mechanism is not — still
  open, tor-agent's to build.** See the Next Steps checklist.
- Dockerfile builds, and Docker-in-Docker vs. a rootless pusher (e.g. `skopeo`) for
  pushing images from CI — open.
- This platform has no `cert-manager`; TLS ends at the network edge, upstream of the
  cluster. What issues (or doesn't issue) a cert for Epinio's own endpoints is open.
- This platform has no `NetworkPolicy` anywhere yet, and builds would run arbitrary
  user-submitted code beside platform workloads in the same cluster. Not addressed by
  Epinio's existence alone.

**Until these report back from the proof-of-concept, nothing below should be read as
"ready to build."** It's the shape the work takes if the gates pass.

---

## Identity gates passed (2026-10-20) — the biggest risk is resolved

`urb-agents#1917`: the lab proof-of-concept's two identity gates (the bolded,
go/no-go-deciding ones) both passed. All three OIDC identity providers Epinio's bundled
Dex needs to authenticate against are proven working, each mapping its own groups to the
same shape — **one admin namespace per team**:

- GitHub org/teams
- Authentik (this platform's own identity provider)
- Okta (a third provider, proving the pattern isn't specific to either of the first two)

Each was proven with two separate, self-controlled test identities logged in
simultaneously — real cross-team namespace isolation, confirmed from Epinio's own
authorization-middleware logs, not inferred from config alone.

**This does not make the earlier open items below resolved — only the OIDC claim-mapping
question specifically.** Object store wiring, cert issuer, and network isolation (next
section) are still open.

### A secrets-mechanism requirement from Terje, binding on this document's eventual PLANs

> *"\[Epinio's] secrets … must go through UIS's own secrets mechanism —
> `provision-host/uis/templates/secrets-templates/` (`00-master-secrets.yml.template`
> under `urbalurba-secrets`, `stringData`, with LocalDev-safe defaults in
> `00-common-values.env.template`) — the same pattern every other UIS service uses."*

The lab PoC proved the identity gate with direct Helm-values injection — the right scope
*for proving it*, explicitly **not** the shape the real integration should copy. Whatever
`PLAN-service-epinio-003-identity.md` (see Next Steps) ends up being, its GitHub
OAuth/Dex/Authentik/Okta connector secrets are UIS-secrets-template entries, not
hand-wired Helm values.

### Five Dex/chart gotchas for whoever writes that PLAN (none are UIS bugs — upstream behavior)

1. `dex.connectors[].config.scopes` **replaces** Dex's default scope set rather than
   adding to it — list `profile`/`email` explicitly alongside any custom scope (`groups`),
   or Dex's callback fails on a missing `name` claim.
2. A generic `oidc` connector needs `insecureEnableGroups: true` before it parses ANY
   `groups` claim, even with the scope granted and the claim present upstream.
3. Dex only reads its config Secret at startup — any change needs an explicit
   `kubectl rollout restart deployment/dex` afterward. A plain `helm upgrade` will not
   restart the pod on its own, since nothing in the pod template changes.
4. Okta specifically: its default authorization server sends no `email_verified` claim,
   and Dex requires one by default — `insecureSkipEmailVerified: true` is the fix.
5. Okta specifically: its default authorization server ships with no access policy —
   every login fails at `/authorize` until one exists. Only surfaces by running a real
   login, not by inspecting the applied config.

### Six real `urbalurba-infrastructure` bugs found during the lab PoC — now filed

Filed as GitHub issues rather than re-described here:
[#565](https://github.com/helpers-no/urbalurba-infrastructure/issues/565) (ambiguous
authentik postgres-bootstrap error),
[#566](https://github.com/helpers-no/urbalurba-infrastructure/issues/566) (hardcoded
kubeconfig context name assumption),
[#567](https://github.com/helpers-no/urbalurba-infrastructure/issues/567) (`uis status`
doesn't detect a stale `external-services.yaml` target),
[#568](https://github.com/helpers-no/urbalurba-infrastructure/issues/568)
(`NEKO_CDP_TOKEN` ignores its template value),
[#569](https://github.com/helpers-no/urbalurba-infrastructure/issues/569) (`-v`/`-vvv`
debug guidance risks dumping secrets — partial fix merged, broader sweep still open),
[#570](https://github.com/helpers-no/urbalurba-infrastructure/issues/570) (Authentik's
shipped IngressRoute has no real certificate, breaks strict-TLS OIDC clients — this one
in particular blocks a clean Dex↔Authentik wiring until this platform has a cert-issuing
story, which it doesn't today).

### One open question for Terje — not decided here

Should the real UIS integration reuse the PoC's exact identity-provider registrations (the
GitHub OAuth app, the Authentik blueprint, the Okta org), or does whoever builds the real
integration provision fresh ones per real cluster? Raised on `urb-agents#1917`; affects how
`PLAN-service-epinio-003-identity.md`'s secrets-template entries get populated, so worth an
answer before that PLAN is written, not during it.

---

## The seam: Epinio is a third path, not a variant of either side of the existing rule

[application-deployment.md](../../../contributors/rules/application-deployment.md) draws
one line: *does the application bring its own workload (ArgoCD), or does it configure a
platform service to run its code (`uis`)?* Epinio matches neither branch of that test —
it **builds** a workload from source the developer never writes as a Kubernetes manifest,
and then **it** deploys and reconciles that workload, not ArgoCD and not `uis configure`.

Forcing Epinio into either existing branch would misdescribe it:
- It is not "`uis` provisions a platform service" — there is no Helm values overlay or
  generated password being written here; the developer's own code is what runs.
- It is not "ArgoCD deploys the workload" — there is no manifest in the developer's repo
  for ArgoCD to reconcile against; Epinio generates the workload at push time.

**Proposed exception, stated the same way the existing rule is stated:**

> `uis` provisions. ArgoCD deploys what a repo declares as a manifest. **Epinio builds
> and deploys what a repo does not declare as a manifest at all** — the self-service,
> buildpack, "push and get a URL" path, for teams who want Heroku/Vercel-shaped ergonomics
> instead of writing Kubernetes YAML.

This needs to be adopted as a **written exception** to the 2026-09-07 rule, not folded
in silently — the existing rule's table is a decision record, and a third path changes
its "owns / why it cannot be the other one" test. The rule document should gain a row,
not be contradicted by omission elsewhere.

### The test, extended

| | mechanism |
|---|---|
| Brings its own workload as a manifest | ArgoCD — `uis argocd register` |
| Configures a platform service to run its code | `uis` — a template declaration |
| **Brings source code and wants it built and run, with no manifest** | **Epinio — `epinio push`, UIS-wrapped** |

A team can still move from Epinio to ArgoCD later (export the generated manifest,
register it) — that migration path is a natural consequence of the shape above, not
something this document needs to build.

---

## Proposed UIS CLI surface, by analogy with the existing ArgoCD integration

The existing `uis argocd register/remove/list/verify` commands
([argocd-commands.md](../../../developing/argocd-commands.md)) are the closest precedent
in this repository for "a platform's native CLI, wrapped by `uis` so the operator doesn't
need direct cluster access." The same shape, not a new one, is proposed for Epinio:

```bash
uis deploy epinio                        # installs Epinio onto the cluster (a service, like argocd)
uis epinio namespace create <team>       # creates the per-team namespace
uis epinio push <team> <app> <path>      # wraps `epinio push`, scoped to the team namespace
uis epinio list <team>                   # status, like `uis argocd list`
uis epinio logs <team> <app>             # no-kubeconfig log access — the actual product ask
```

This keeps Epinio a **service** in UIS's existing sense — numbered, with a
`manifests/NNN-epinio-*.yaml` config and an Ansible playbook under
`ansible/playbooks/`, the same shape every other management-tier service
(ArgoCD included) already has. It does not invent a second service framework.

Numbering: the 600-799 management range has gaps (`623 -> 630`, `630 -> 641`); Epinio
fits there alongside ArgoCD rather than in a new range.

---

## Gate 8 resolved (2026-10-26) — build-safety is a documented v1 limitation, not a defect

`urb-agents#1911`'s full 18-test gate run against the `-test` cluster PoC found Gate 8
failing: a broken `epinio push --git` can take a previously-working app down, with no
automatic protection and no configuration fix — confirmed against Epinio's own CLI (no
rollback/revision command exists). This is specific to the buildpack push path; the
registry-image path (`--container-image-url`, Gate 12) is unaffected, since its build step
runs in CI before anything reaches Epinio.

Decided in [PLAN-service-epinio-002-build-safety](../completed/PLAN-service-epinio-002-build-safety.md)
(`urb-agents#2019`, one of `#1911`'s four pre-production conditions): accept for v1, steer
teams needing broken-build protection to the registry path (already proven, Gate 12), and
bind whatever PLAN later wraps `epinio push` as `uis epinio push` to carry this split
forward rather than rediscover it.

## What stays open until the proof-of-concept reports back

The items in "What is explicitly NOT decided or verified yet" above are not re-summarized
here — they are the gate. Specifically, this document takes no position on:

- ~~The concrete OIDC claim→namespace-role mapping (depends on gate results against both
  identity providers).~~ **Resolved — see "Identity gates passed" above.**
- Whether the object store needs any Epinio-specific bucket/policy shape.
- ~~Whether a cert issuer needs adding for Epinio's own endpoints~~ **Resolved — added
  cert-manager as a new UIS service with a self-signed `uis-ca` ClusterIssuer, see
  [PLAN-system-cert-manager-001-install](../completed/PLAN-system-cert-manager-001-install.md).
  Verified live by imac, 2026-10-20.**
- Network isolation between build workloads and platform workloads — flagged as a real
  gap, not assumed solved by namespace-per-team alone.

## Fallback, if the gate fails

Scoped Argo CD access instead: Dex in front of ArgoCD, per-app roles, and a
rollout-status step added to `uis argocd register` so a developer gets the "did it come
up" signal Epinio would otherwise provide. This reuses the existing ArgoCD path rather
than adding a second deploy mechanism, at the cost of still requiring a manifest in the
developer's repo — i.e., it does not deliver the "no Kubernetes YAML at all" part of the
original ask.

---

## Next steps

- [x] Lab proof-of-concept runs its identity gates — **passed 2026-10-20** (`#1917`)
- [x] Rule exception approved by Terje (`#1915`), PR #564 merged
- [x] Terje's answer on identity-provider reuse-vs-fresh received (`#1919`): fresh
      Authentik, reuse GitHub+Okta. Secrets delivery destination given back; not yet
      confirmed received.
- [x] [PLAN-system-cert-manager-001-install](../completed/PLAN-system-cert-manager-001-install.md)
      and [PLAN-service-epinio-001-install](../completed/PLAN-service-epinio-001-install.md) —
      written, coded, and **verified live by imac on a real Rancher Desktop cluster,
      2026-10-20** (`#1921`). Both moved to `completed/`. Two real bugs found and fixed
      along the way (missing `epinio` secrets-template entry; a chart version bundling
      broken MinIO images) — see the PLANs themselves for detail.
- [x] [PLAN-service-epinio-002-build-safety](../completed/PLAN-service-epinio-002-build-safety.md) —
      Gate 8's finding decided and documented (`#2019`). **Renumbered the two PLANs below
      by one** so this number is not reused: what was `-002-namespace-and-push` is now
      `-003`, what was `-003-identity` is now `-004`.
- [ ] `PLAN-service-epinio-003-namespace-and-push.md` — not started. Must read
      `-002-build-safety`'s decision before designing `uis epinio push`, not rediscover it.
- [ ] `PLAN-service-epinio-004-identity.md` — not started; waits on the two secret files
      ops is delivering (`#1919`)
- [ ] Object store wiring (Garage): **concept proven against ops's own PoC harness only
      (`urb-agents#2019`), 2026-10-26 — ops's own correction, same comment thread.** The
      PoC proof (`service-epinio-poc.yml`, real `-test` cluster, real `garage` guest,
      push/build/restage verified end to end against Garage instead of SeaweedFS) is
      reference material, same shape as the gate 17/18 identity handoff — it does **not**
      touch `625-setup-epinio.yml`/`00-master-secrets.yml.template`, which still point at
      the bundled SeaweedFS. **Still open, and explicitly tor-agent's to build** (not ops's,
      not done by the PoC alone): incorporate Garage as the real UIS mechanism's S3 backend
      — judged against the PoC's proof, not copied blind — then imac tests it on Rancher
      Desktop, then ops live-verifies against the real Garage guest on Proxmox (same
      live-Proxmox-pass requirement every other CORE_SERVICES/LAB_EXTRAS item gets, for
      HA/replication/real-network behavior no test cluster reproduces). One gotcha already
      known from the PoC pass, to carry into that build: `epinio-server` needs an explicit
      `kubectl rollout restart` after an S3 backend swap (Helm re-renders the Secret but
      nothing in the pod template changes — same class gate 18 already found for Dex).
      Network isolation remains open and should be resolved in whichever PLAN touches it,
      not assumed.
- [ ] On a production-rollout no-go from ops's side: fall back to scoped Argo CD access as
      its own PLAN against the existing ArgoCD path (does not block the UIS-side PLANs
      above, which target any cluster, not specifically production)
