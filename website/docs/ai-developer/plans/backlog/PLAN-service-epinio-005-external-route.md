# Plan: a generic external route for a pushed Epinio app

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Live-verified by imac (urb-agents#2044) — one real bug found and fixed

**2026-10-27**: imac tested this live on Rancher Desktop, pushed a real app, exposed it,
confirmed the external `HostRegexp` hostname reaches it through Traefik, confirmed the
original `apps.localhost` route keeps working simultaneously, confirmed re-running with
the same parameters updates rather than duplicates. One real bug found along the way,
fixed in PR #644 — see "Bug found live" below.

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

## Bug found live, fixed in PR #644

A port templated as a leaf nested inside `kubernetes.core.k8s`'s own `definition:` dict
(`port: "{{ epinio_route_port | int }}"`) does not survive as an int — Ansible's non-
native templating stringifies every leaf of a structure that gets walked/reconstructed
that way, regardless of any filter on an individual leaf. Kubernetes' own API then 400s:
`cannot unmarshal string into ... int32`, on every route, every time. Found and verified
live by imac: building the whole `ports`/`services` substructure as one top-level Jinja
expression (an actual list/dict literal evaluated by Jinja itself) and referencing it as
a single value does preserve the native type — confirmed live against the real
Kubernetes API, both tasks `changed`, no error. Ported that exact pattern into
`626-epinio-external-route.yml`.

## Validation

**Met, live, 2026-10-27 (`urb-agents#2044`)**: imac pushed a real app (a genuine
buildpack build), exposed it, confirmed the external `HostRegexp` hostname reaches it
through Traefik (an arbitrary `Host` header via the same local port Rancher Desktop
already forwards `*.localhost` through), confirmed the original `apps.localhost` route
keeps working simultaneously, and confirmed re-running with the same parameters updates
(`ok`, not `changed`) rather than duplicating — exactly one Service and one IngressRoute
both times. This was run against imac's own container-local patch for the bug above, not
the code as it stood in the repo at the time; PR #644 ports that exact verified pattern
into the shipped file, so the shipped code now matches what was actually tested, but has
not been independently re-run against a live cluster since.
