# Investigate: a green UIS test run must not depend on the development topology

**Status**: backlog · **Raised by**: ops, at Terje's direction, 2026-08-25
**Source**: `terchris/home` → `ai-developer/for-assist-topology-coverage-requirement.md`
**Domain**: system

This is a **requirement from ops; the mechanism is ours.** Filed here because the
requirement was accepted verbally and then existed only as a message — a queue position
with no artefact behind it.

## The problem

Three defects surfaced in one morning, all found by hand, on production, one at a time.
All three are one class: **an assumption true only of the development topology.**

| # | Defect | Why it hid |
|---|---|---|
| F1 | `postgresql-0` hardcoded in 3 playbooks | imac *has* a `postgresql-0`; it passed the postgrest verify 3 rounds without noticing |
| F2 | 13 of 15 `uis verify` commands never passed `target_host` | imac's context is *named* `rancher-desktop`, the fallback value |
| F3 | `secrets apply` silently adds nothing for services newer than the install | install *age*, not shape |

The tester and production differ on exactly two axes, and all three defects lived there:

| | imac (tester) | asgard (production) |
|---|---|---|
| kubeconfig context | `rancher-desktop` | `asgard` |
| postgres shape | `postgresql-0`, in-cluster StatefulSet | `postgresql-<hash>`, Deployment proxying to Odin pg |

imac is prod-matched on *versions* (k8s 1.36, Traefik v3) but not on *topology*. It
declares `postgresql` in `external-services.yaml` yet still runs the in-cluster
StatefulSet — **the proxy path has never been exercised by the tester.**

## Terje's reframing: the shim already exists — ask what reaches around it

The service shim was built precisely to make this difference invisible: same Service
name, same labels, and a first container carrying bash+psql so `kubectl exec … psql`
keeps working. Hardcoding the pod *name* was the one thing that defeated it.

So F1 was never a shim failure — it was a playbook **reaching around** the shim. The
useful question is therefore not *"does it work on both topologies?"* but:

> **Does anything address a dependency by an identity the shim does not guarantee?**

That is answerable by a lint in CI, with no second cluster. ⚠️ It explains **F1 only** —
F2 is CLI plumbing with no database in it, F3 is install-time template refresh. Do not
let the shim framing over-explain them.

## What must become true (outcomes, not mechanisms)

1. A green test run must not depend on the context being named `rancher-desktop`.
2. The external-postgres proxy topology must be exercised **before** production.
3. **Both** topologies stay covered — in-cluster postgres with a default context name is
   a legitimate supported configuration. Switching the tester to production's shape moves
   the blind spot rather than closing it. This is a small matrix, not a migration.
4. A wrong or missing target must fail loudly as a **configuration error**, never as
   "the service did not answer". F2 reported a healthy dagster as broken.

## Already shipped against this (2026-08-25)

- `provision-host/uis/lib/verify-target.sh` — `uis_target_host()` + `uis_verify_preflight()`;
  all 15 verify call sites route through it, and a missing target now refuses to start
  with a configuration error. **Covers outcomes 1 and 4.**
- `provision-host/uis/lib/pg-connection.sh` + `tests/static/test-postgres-connection-shape.sh`
  — static gate failing any `psql` without a host and any hardcoded `postgresql-0`.
  **A first instance of the lint answer to F1.**
- CI path filters (`ansible/**`, `uis`) so these paths actually trigger the test workflow.

Outcome **2 remains open** — nothing yet exercises the proxy topology.

## Open questions

1. Second context on imac, a k3d/kind cluster in CI, a test matrix, or renaming the dev
   context? Not specified by ops — our call.
2. Is the lint generalisable beyond postgres to *any* shimmed dependency, i.e. a check
   for "addresses a dependency by an identity the shim does not guarantee"?
3. **Install age is a second axis** (F3) and is not addressed by any topology matrix.
   Does it belong here or in its own investigation?
4. Offered by ops, not prescribed: if playbooks connected to `postgresql.<ns>.svc:5432`
   from a throwaway client pod, there would be no pod identity to get wrong and the proxy
   would not need to carry psql. Trade-offs unweighed — a client image to pull, secret
   handling on the wire. Ours to decide.

## The standing lesson

> **A green round on one topology says nothing about the other.**

Now a rule in `PLAN-atlas-asgard-001`: every result states its topology. This
investigation is the systemic version — the rule catches it in reports, coverage catches
it before reports exist.
