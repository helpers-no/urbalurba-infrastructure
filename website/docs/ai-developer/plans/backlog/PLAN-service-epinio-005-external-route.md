# Plan: a generic external route for a pushed Epinio app

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Implemented (PR #641) — not yet live-tested, imac's turn

**Goal**: give an Epinio-pushed application a tunnel-reachable external route. Epinio's
own auto-generated per-app Ingress only answers the LAN/nip.io case (it pins Epinio's own
`global.domain` on the TLS `websecure` entrypoint), so there is no way today to reach a
pushed app the same way every other externally-exposed UIS service is reached (a
Cloudflare tunnel forwarding to Traefik's plain `web` entrypoint, matched by a
`HostRegexp` IngressRoute).

**Migration source**: `urb-agents#1909`/`#1911`'s Epinio PoC on a lab test cluster — gate
3, proven live there. Full gate-by-gate record: `INVESTIGATE-host-epinio-rollout.md` in
`terchris/home`. Migrated via `urb-agents#2040`.

**Related**: [PLAN-service-epinio-001-install](../completed/PLAN-service-epinio-001-install.md),
[PLAN-service-epinio-002-build-safety](../completed/PLAN-service-epinio-002-build-safety.md)

**Created**: 2026-10-27

---

## Why this is a playbook, not a manifest

Every other `HostRegexp` IngressRoute in this repository belongs to one fixed, known-at-
build-time service (neko, dagster, grafana, …) — one manifest per service, hand-authored,
shipped with the image. An Epinio app's name is chosen by whoever runs `epinio push`, at
push time. There is nothing to bake into a shipped manifest; the mechanism has to be a
reusable playbook invoked per app instead.

## What was built

- `ansible/playbooks/626-epinio-external-route.yml` — three required parameters
  (`epinio_route_app_name`, `epinio_route_namespace`, `epinio_route_port`), asserted
  present, no default for any of them. Confirms the target app actually exists (by
  Epinio's own `app.kubernetes.io/name` label) before routing to it. Creates its own
  stable `Service` selecting by that same label, rather than Epinio's auto-created one
  (whose name carries a hash suffix proven live, during the PoC, not to be guaranteed
  stable across a redeploy of the same app) — then an `IngressRoute` on the plain `web`
  entrypoint with a `HostRegexp` match, the same convention every other externally-
  exposed service in this repository already uses.
- `scripts/epinio/epinio-expose-route.sh` — the documented way an operator actually runs
  it, matching `scripts/argocd/argocd-register-app.sh`'s own shape (required env vars,
  missing-parameter check, invokes the playbook).
- `provision-host/uis/tests/static/test-epinio-external-route-required-params.sh` —
  asserts both the playbook and the wrapper actually refuse to proceed with any parameter
  missing, and that the created resources are named from the parameter (idempotent re-run,
  not a second resource each time). Mutation-tested.
- A short section added to `website/docs/services/management/epinio.md` documenting the
  invocation.

## Validation

**Not yet run against a live cluster** — same caveat as every PLAN in this repository
without one. What's actually checked here: `ansible-playbook --syntax-check`, the full
static+unit suite, and the mutation-tested static test above.

**Still needed, live** (imac's side, same division of labour as every other service in
this repository): push a real app, run the script, confirm the external hostname actually
reaches it through Traefik/the tunnel, confirm the original LAN/nip.io route is
unaffected, and confirm re-running with the same parameters updates rather than
duplicates.
