# Plan: Epinio's Dex connector against this platform's identity providers

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Partially live-tested by imac (urb-agents#2044) — GitHub connector verified short of browser login; Authentik/Okta blocked, now fixed

**Goal**: wire Epinio's own bundled Dex to up to three identity providers (GitHub,
Authentik, Okta), each mapping its own groups/teams to namespace roles, instead of
Epinio's default basic auth. Referenced by name in `625-setup-epinio.yml` since that
playbook first shipped — this is the piece it always deferred.

**Migration source**: `urb-agents#1909`/`#1911`'s Epinio PoC on a lab test cluster —
gates 17 (GitHub) and 18 (Authentik, Okta), proven live there. Full gate-by-gate record:
`INVESTIGATE-host-epinio-rollout.md` in `terchris/home`. Migrated via `urb-agents#2040`.

**Related**: [PLAN-service-epinio-001-install](../completed/PLAN-service-epinio-001-install.md),
[PLAN-service-epinio-004-object-storage](./PLAN-service-epinio-004-object-storage.md)

**Created**: 2026-10-27

---

## Generalized from one hardcoded setup into real parameters

The PoC proved this against one specific GitHub org/teams and one specific Authentik
install's groups. None of that — org name, team names, group names, role mappings — is
generic UIS config; it is one install's own identity structure. Nothing from the PoC's
real values is committed here: each connector is `enabled: false` by default, and an
operator supplies the real structure via `-e @vars-file.yml` (the nested shape does not
fit flat `-e k=v` pairs). Only the OAuth client secrets go through the normal secrets
pipeline (`EPINIO_DEX_GITHUB_CLIENT_SECRET` etc.) — client IDs are not secret (GitHub's
own OAuth spec treats them as public) and are ordinary playbook vars instead.

## The five Dex gotchas, found live during the PoC, baked in rather than left to be rediscovered

1. `dex.connectors[].config.scopes` **replaces** the default set, not adds — `profile`/
   `email` are listed explicitly alongside `groups` in every connector, or Dex's callback
   fails on a missing `name` claim.
2. A generic `oidc` connector needs `insecureEnableGroups: true` before any `groups`
   claim is parsed at all, even when the scope is granted and present.
3. Dex only reads its connector config (a Secret, mounted as a volume) at startup — a
   Helm values change needs an explicit `kubectl rollout restart deployment/dex` after,
   every time. `627-setup-epinio-identity.yml`'s own restart task is unconditional, not
   gated on "did the config actually change" — confirmed live that a config change with
   no restart leaves the OLD connector list serving.
4. Okta's default authorization server sends no `email_verified` claim at all —
   `insecureSkipEmailVerified: true` on that connector only.
5. `admin:<namespace>` alone is not enough — Epinio's own API returns 403 on every call,
   including a bare namespace list, unless a bare `"user"` role is also granted. Every
   group in every connector gets `user` alongside whatever `admin:<ns>` roles it maps to.

## The one genuinely new platform capability this needed: cross-namespace trust

Dex runs in the `epinio` namespace; Authentik's own TLS certificate (already real,
`urb-agents#1917` bug #570) lives in the `authentik` namespace. Kubernetes Secrets cannot
cross namespaces on their own. **New UIS service: `reflector`**
(`emberstack/kubernetes-reflector`, Helm chart version 9.1.9, confirmed live against the
chart's own repo index 2026-10-27) — mirrors an annotated Secret into other namespaces,
kept in sync automatically on every renewal. `627-setup-epinio-identity.yml` patches
Authentik's existing Certificate with the reflection annotations (only when the
authentik connector is enabled), reading the Certificate's current annotations first and
**unioning** the target namespace list rather than overwriting it — a second future
consumer of the same Certificate must not have its own namespace silently dropped by
this playbook re-running.

## What was built

- **`provision-host/uis/services/management/service-reflector.sh` +
  `ansible/playbooks/028-setup-reflector.yml` / `028-remove-reflector.yml`** — the new
  service, modeled directly on `service-external-secrets.sh`'s shape. Remove refuses if
  anything is still annotated for reflection, same precedent as external-secrets'
  own ClusterSecretStore check.
- **`ansible/playbooks/627-setup-epinio-identity.yml`** — validates each enabled
  connector's required fields and secret; when authentik is enabled, patches Authentik's
  Certificate (union, not overwrite), waits for the mirrored Secret to actually land,
  renders and merges the Epinio OAuth2/OIDC blueprint into the existing `app-slot1`
  expansion slot (reusing the exact mechanism `073-authentik-3-app-slot1-blueprint.yaml`
  already provides, the same way `service-authentik-epinio-provider.yml` did during the
  PoC); renders `manifests/627-epinio-identity-values.yaml.j2` and applies it with
  `helm upgrade --reuse-values` (merges on top of `625-setup-epinio.yml`'s own domain/
  TLS/storage values rather than resetting them); patches Dex's Deployment to mount the
  mirrored CA (chart has no values-level way to add this volume — confirmed via
  `helm show values`); restarts Dex unconditionally; verifies Epinio still answers.
- **`manifests/627-epinio-identity-values.yaml.j2`** — the `dex.connectors`/
  `rolesMapping` Helm values, each connector block independently gated.
- **`manifests/627-epinio-authentik-blueprint.yaml.j2`** — the Authentik-side
  OAuth2Provider + Application, reusing the existing "Service Groups Mapping" scope
  mapping `073-authentik-service-protection-blueprint.yaml.j2` already creates, rather
  than declaring a second, duplicate one.
- Three new secrets (`EPINIO_DEX_GITHUB_CLIENT_SECRET`/`_AUTHENTIK_CLIENT_SECRET`/
  `_OKTA_CLIENT_SECRET`) in the standard secrets-templates pipeline.
- Two new static tests, both mutation-tested: `test-epinio-identity-structure.sh`
  (required-param gating, the union-not-overwrite logic, the unconditional restart,
  `no_log`, `--reuse-values`) and three new assertions in
  `test-jinja-templates-render.sh` (per-connector-combination rendering, `rootCAs`/
  `insecureSkipEmailVerified` land on the right connector only, the bare `user` role is
  never dropped).

## Deliberately not consolidated into the existing generic `protected_services` oauth2 mechanism

`073-authentik-service-protection-blueprint.yaml.j2` already has a generic `type: oauth2`
branch for any service in `AUTH10_PROTECTED_SERVICES`. It would in principle avoid a
second, bespoke blueprint file. Not used here, on purpose: that branch has no default
example anywhere in this repository and is unexercised by any currently-configured
service — this would be its first real use, and routing Epinio's own already-proven
(during the PoC) bespoke mechanism through it would mean trusting two unproven things at
once instead of one. Worth revisiting as a future consolidation once that generic path
has a real, tested consumer of its own.

## Bug found live, fixed in PR #644: reflector collides with Epinio's own bundled copy

Epinio's own upstream Helm chart already bundles `emberstack/reflector` as a subchart
dependency (confirmed live: release `epinio`, chart `reflector-10.0.58`), including a
cluster-scoped `ClusterRole` literally named `reflector`. The standalone `reflector`
service (028-setup-reflector.yml, same upstream chart, pinned `9.1.9`) tried to create a
`ClusterRole` with that same name under a different release, and Helm correctly refused
it. This is not a corner case — it is the exact combination this whole plan exists for
(anyone installing Epinio, then needing the Authentik connector's cross-namespace trust,
hits this every time). Fixed by detecting any already-running reflector controller
cluster-wide (its own design has no release-scoped RBAC — any controller watches
annotated Secrets cluster-wide regardless of which release deployed it) and skipping the
standalone install when one is already present. Found live by imac; not something they
attempted to resolve themselves (a design call, correctly left for this repo).

## Validation

**GitHub connector, met live except the interactive sign-in itself, 2026-10-27
(`urb-agents#2044`)**: imac used a real GitHub org/team, decoded the rendered `dex-config`
Secret directly (clientID/org/teams/redirectURI all correct, `rolesMapping` pairs `user`
unconditionally with the matched group's `admin:<ns>` role — gotcha 5's fix genuinely
present), confirmed Dex actually restarted and its own logs show the connector loading.
**Not verified**: an actual interactive sign-in through GitHub's consent screen — no
browser-automation tool was available in that environment, flagged explicitly rather than
claimed. The "no matching group → no roles" case is sound by construction (no catch-all
entry in the rendered `rolesMapping`) but is inference from the rendered config, not an
observed failed login.

**Authentik connector: was entirely blocked** by the reflector/Epinio collision above —
task 11 (confirming the mirrored Secret lands) is a hard fail with no standalone
`reflector` release installable. Not yet re-tested against the fix.

**Okta connector: not attempted** — no real Okta tenant available; shares the
Authentik-identical `insecureEnableGroups`/`insecureSkipEmailVerified` code path already
partially exercised by template inspection.

**Still needed, live**: re-run the Authentik connector now that the reflector collision
is fixed — deploy `reflector` (or confirm Epinio's bundled copy is detected and reused),
run this playbook with the authentik connector enabled, confirm the mirrored Secret lands
and sign in through it, then Okta with a real tenant. Confirm a user with no matching
group lands with none (not admin by accident) — the one piece still only checked by
inference, not an observed failed login.
