# Investigate: Epinio Deploy Path for UIS

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog — gated on an external lab proof-of-concept, not ready for a PLAN

**Goal**: Decide how UIS itself (CLI surface, service layout, docs) should incorporate
an Epinio-based self-service deploy path — "push code, get a URL and status back, read
logs with no kubeconfig" — alongside the existing ArgoCD path, once the proof-of-concept
below has cleared its gates.

**Priority**: Low until the gates below report back. This file exists so the decision
isn't re-derived from scratch when they do.

**Last Updated**: 2026-10-19

**Related**:
- [Rules for Deploying Applications](../../../contributors/rules/application-deployment.md) —
  the 2026-09-07 `uis provisions / ArgoCD deploys` rule this proposal takes an explicit
  exception to
- [INVESTIGATE-service-argocd-dct-deploy.md](./INVESTIGATE-service-argocd-dct-deploy.md) —
  prior art for a "push and get a URL back" developer experience, built on the ArgoCD path
- `urb-agents#1909` — the platform evaluation (Kubero/KubeVela/Devtron/Epinio) and the
  product requirement behind this
- `urb-agents#1910` — the handoff that scoped this document to "how UIS builds it,"
  separating it from the production-rollout decision, which is tracked elsewhere

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

- **Biggest risk**: how Epinio maps OIDC claims/groups to namespace roles. Untested.
  Upstream Epinio has no issue open for this yet.
- Epinio's bundled Dex against either of this platform's identity providers: untested
  in both directions.
- `epinio push --git` against a self-hosted (non-GitHub/GitLab) git forge: should work
  per Epinio's source (it's a plain git clone), but the auto-deploy webhook is
  GitHub/GitLab-only and isn't needed for this platform's CI-triggered flow.
- Whether Epinio can pull from the forge's own registry with credentials.
- The object store as Epinio's S3 backend: untested with Epinio specifically.
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

## What stays open until the proof-of-concept reports back

The items in "What is explicitly NOT decided or verified yet" above are not re-summarized
here — they are the gate. Specifically, this document takes no position on:

- The concrete OIDC claim→namespace-role mapping (depends on gate results against both
  identity providers).
- Whether the object store needs any Epinio-specific bucket/policy shape.
- Whether a cert issuer needs adding for Epinio's own endpoints, or whether its ingress
  rides the same edge-terminated-TLS pattern every other UIS service already uses.
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

- [ ] Lab proof-of-concept runs its gates (owned outside this document)
- [ ] On a pass: amend
      [application-deployment.md](../../../contributors/rules/application-deployment.md)
      with the third-path exception above, as a dated decision record the same way the
      2026-09-07 rule is recorded
- [ ] Split this INVESTIGATE into ordered PLANs once the gated items have answers —
      expected shape: `PLAN-service-epinio-001-install.md` (the service itself, no
      developer-facing surface yet), then `-002-namespace-and-push.md`, then
      `-003-identity.md` once OIDC claim mapping is proven
- [ ] On a fail: write up the fallback as its own PLAN against the existing ArgoCD path
