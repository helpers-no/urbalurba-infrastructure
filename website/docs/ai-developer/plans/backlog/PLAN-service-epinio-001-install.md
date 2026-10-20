# Plan: Epinio install (no identity, no custom storage/registry wiring)

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog — code written, not yet run against a live cluster

**Goal**: `uis deploy epinio` installs Epinio against this platform's existing Traefik,
with Epinio's own bundled defaults for everything this PLAN deliberately does not touch.
First of three ordered PLANs splitting
[INVESTIGATE-service-epinio-deploy-path](./INVESTIGATE-service-epinio-deploy-path.md) —
see that doc for the full decision record (`urb-agents#1909/#1910/#1915/#1917`).

**Prerequisites**: [PLAN-system-cert-manager-001-install](./PLAN-system-cert-manager-001-install.md)
must ship first — Epinio's chart requires cert-manager's CRDs before its own install pass.

**Last Updated**: 2026-10-20

---

## Scope — deliberately narrow

This PLAN proves one thing: **Epinio installs and comes up healthy.** It does NOT:

- Wire Epinio's bundled Dex to this platform's identity providers (GitHub/Authentik/Okta)
  — that's `PLAN-service-epinio-003-identity`, and needs the gate-17/18 findings
  (`urb-agents#1917`) plus Terje's reuse-vs-fresh decision (`urb-agents#1919`) to not go
  stale before it's written.
- Wire Epinio's object storage to this platform's Garage, or its registry to Forgejo —
  Epinio uses its own bundled SeaweedFS + bundled registry here, exactly as the lab PoC's
  own gate-1 install did (deliberately, per the PoC's own `epinio-poc-values.yaml` header:
  prove the install first, without pre-deciding later gates' open questions).
- Add the `uis epinio push/list/logs/namespace` CLI surface —
  `PLAN-service-epinio-002-namespace-and-push`.

## What this PLAN ships

- `provision-host/uis/services/management/service-epinio.sh` — `uis deploy epinio` /
  `uis undeploy epinio`, `SCRIPT_REQUIRES="cert-manager"`.
- `ansible/playbooks/625-setup-epinio.yml` — refuses up front if `cert-manager`'s `uis-ca`
  ClusterIssuer isn't found (not just relying on `SCRIPT_REQUIRES`'s own check — a second,
  more specific refusal naming the actual missing thing), then installs the
  `epinio/epinio` Helm chart with `certManager.install: false` / `enabled: true` and
  `ingressClassName: traefik` on both `server` and `ingress`.
- `ansible/playbooks/625-remove-epinio.yml`.
- `DEFAULT_EPINIO_DOMAIN=apps.localhost` added to
  `provision-host/uis/templates/secrets-templates/00-common-values.env.template` —
  deliberately NOT bare `localhost`, since every other UIS service already claims
  `<service>.localhost` directly and a developer-chosen Epinio app name could collide with
  an existing service name in that same namespace.

## 🔴 What is NOT verified — read before trusting this

- **No live cluster in this environment.** `ansible-playbook --syntax-check` only.
- **The Epinio Helm repo URL/chart name/version were not confirmed against a live index**
  — no internet access where this was written. Before running for real:
  `helm repo add epinio https://epinio.github.io/helm-charts && helm repo update &&
  helm search repo epinio/epinio --versions` — correct `625-setup-epinio.yml` if wrong.
- **The default-credential secret name/label in the playbook's final output message is a
  guess**, flagged as such inline — confirm against a real install and fix the message,
  don't trust it as written.
- **`apps.localhost` as a wildcard domain**: relies on Traefik's Kubernetes-native
  `Ingress` support (not just its own `IngressRoute` CRD) picking up whatever Ingress
  objects Epinio's server creates per pushed app, and on `*.localhost` resolving to
  loopback the same way the rest of this platform's `<service>.localhost` convention
  already depends on. Not independently re-verified for Epinio's dynamic, per-app-name
  case specifically.

**This is imac's job to run and report back on.**

## Acceptance Criteria

- [ ] `uis deploy cert-manager && uis deploy epinio` succeeds on a fresh Rancher Desktop
      cluster
- [ ] `kubectl get pods -n epinio` shows the server pod Running and Ready
- [ ] `https://epinio.apps.localhost/ready` responds (or the equivalent for whatever real
      `DEFAULT_EPINIO_DOMAIN` is configured)
- [ ] `uis undeploy epinio` removes it cleanly
- [ ] Docs page (`website/docs/services/management/epinio.md`, auto-generated — already
      generated and committed with this PLAN) renders correctly

## Next steps

- [ ] imac runs this against a real cluster, reports what broke
- [ ] On success: `PLAN-service-epinio-002-namespace-and-push`
- [ ] `PLAN-service-epinio-003-identity` waits on the secrets ops is delivering per
      `urb-agents#1919` (destination given, not yet confirmed received)
