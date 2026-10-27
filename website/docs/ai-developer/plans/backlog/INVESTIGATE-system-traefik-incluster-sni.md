# Investigate: Traefik's ClusterIP doesn't present the right certificate for a direct in-cluster strict-TLS connection

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog — found live, not yet designed; explicitly NOT specific to Epinio

**Goal**: figure out how an in-cluster workload reaches another `HostRegexp`-routed
service through Traefik with a certificate that actually validates under strict TLS
verification — today it can't, for any such service, not just the one that happened to
surface it.

**Found by**: imac, live on Rancher Desktop, while testing the Authentik connector for
`urb-agents#2040`'s Epinio migration (`urb-agents#2045`). Deliberately filed as its own
document rather than folded into that migration — per imac's own recommendation, this is
bigger than Epinio and bigger than Dex.

**Related**: `website/docs/ai-developer/plans/backlog/PLAN-service-epinio-003-identity.md`
(the plan that surfaced this — its own Authentik connector remains blocked by this issue
even after its own two bugs are fixed)

**Created**: 2026-10-27

---

## What's actually measured, not guessed

With Dex's `rootCAs` correctly pointed at a real, mirrored copy of Authentik's own TLS
certificate (see `627-setup-epinio-identity.yml`), and with a `hostAliases` entry
resolving `authentik.localhost` to Traefik's ClusterIP instead of loopback (the
`.localhost`-special-TLD trap, same class as `urb-agents#1928`), Dex's connection to
Authentik still fails TLS validation:

```
certificate is valid for ...traefik.default, not authentik.localhost
```

imac probed this directly: `openssl s_client -servername authentik.localhost` against
Traefik's own ClusterIP:443 gets back `CN=TRAEFIK DEFAULT CERT` — Traefik's own ad-hoc
self-signed default certificate, not Authentik's real one, even though the SNI hostname
requested is exactly the one Authentik's `IngressRoute` matches via `HostRegexp`.

**Confirmed not new, not Epinio-specific, not Authentik-specific**: the identical probe
against `argocd.localhost` — a route that has been live and working for 26 days — gets
the exact same wrong certificate. This is a standing characteristic of how Traefik's bare
in-cluster `ClusterIP:443` answers a direct TLS connection, true for every
`HostRegexp`-routed service in this repository, not a defect introduced by this plan.

## Why this never surfaced before

Every prior in-cluster consumer of a `HostRegexp`-routed service has avoided needing
this exact path:

- Plain HTTP (no TLS at all) for most in-cluster service-to-service calls.
- TLS with verification skipped (`validate_certs: false`, used by this repository's own
  install playbooks when checking a service came up — correctness-irrelevant for a
  reachability probe, but not a model for a real client).
- Routing out through the external tunnel at a different termination point entirely,
  which presents a real certificate because that's a different network path, not this
  one.

Dex's `oidc` connector is the first thing in this repository that does **strict** TLS
verification of another in-cluster `HostRegexp`-routed service, from inside the cluster,
over its real hostname. Nothing before it needed this exact combination, which is why a
26-day-old working route (`argocd.localhost`) never revealed the same underlying gap.

## What's not decided here

- **Why** Traefik's ClusterIP serves its own default cert instead of a `HostRegexp`-
  matched route's real one for a direct TLS connection, when the identical Host header
  routes correctly for plain HTTP and (presumably) for the external tunnel path. Whether
  this is an SNI-vs-Host-header distinction in how Traefik's `websecure` entrypoint
  selects a router, a certificate-store resolution order issue, or something about how
  this platform's own IngressRoutes declare their TLS, is not established — needs reading
  Traefik's own router-matching/TLS-SNI resolution logic for this version, not guessed.
- **What the real fix looks like.** Candidates not evaluated here: giving Dex (or any
  such in-cluster client) a path to the same address/port that host-side `*.localhost`
  traffic actually uses (the LoadBalancer-assigned IP via Rancher Desktop's own port
  forwarding) rather than the ClusterIP; a Traefik-side TLS/SNI configuration change so
  the `websecure` entrypoint resolves the right certificate for ClusterIP-origin
  connections too; or something else not yet considered. This is a design decision, not
  a quick patch — explicitly not attempted by imac as tester, and not decided here.
- **Scope beyond Rancher Desktop.** Not checked against Proxmox or any other platform
  this repository targets — the `.localhost` special-TLD half of the problem is
  specific to the loopback-dev-domain convention, but the Traefik ClusterIP/cert-
  resolution half may or may not be.

## Honest limits of what's in this document

Everything measured above is read from imac's own live report (`urb-agents#2045`) —
exact probe commands and outputs, not summarized from memory. No code has been written
here and no design has been chosen. This document exists to make the finding
discoverable and trackable on its own, separate from the Epinio migration that happened
to surface it, per imac's own explicit recommendation not to fold it into that scope.
