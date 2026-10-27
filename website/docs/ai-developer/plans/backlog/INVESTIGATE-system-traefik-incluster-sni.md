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

## Correction to the original finding, and a sharper hypothesis

The original report's "confirmed not new" evidence — the identical probe against
`argocd.localhost` getting the same wrong cert — is **not actually corroborating
evidence of a platform-wide bug**. Checked directly: `manifests/221-argocd-ingressroute.yaml`
has exactly one `IngressRoute`, on the plain `web` entrypoint only — there is no
`websecure`/TLS route for ArgoCD at all, so any HTTPS/SNI probe against it falling
through to Traefik's default certificate is completely expected, not surprising. This
doesn't mean the underlying finding is wrong — Authentik's own TLS route genuinely fails
the same way, and that's the real data point — but the "26-day-old working route" framing
overstated how much independent confirmation that comparison actually provides.

**What Traefik's own documentation says, confirmed, not assumed:** TLS certificate
selection happens purely by matching the client's SNI against Traefik's own certificate
store — HTTP router rules (`Host`/`HostRegexp`) play no part in that step at all, since
they're only evaluated after the TLS handshake completes. An SNI with no matching
certificate in the store falls back to Traefik's generated default
("TRAEFIK DEFAULT CERT"). Authentik's own certificate (`076-authentik-server-tls-
certificate.yaml.j2`) has `authentik.localhost` as one of its `dnsNames` — so on this
model, the SNI sent should match exactly, and the real cert should be selected
regardless of which Service (ClusterIP or LoadBalancer) physically delivered the TCP
connection to Traefik's listener — Traefik itself has no visibility into which Service
was used; it only sees a port and a TLS ClientHello.

This narrows the real question considerably: either (a) Traefik's cert store never
actually registered `authentik-server-tls` for that SNI at all (in which case the
in-cluster-vs-host-side distinction is a red herring too, and the real cert may never
have been served correctly to **anyone**, discovered now only because Dex is the first
client to validate strictly rather than click through a browser warning), or (b)
something about the ClusterIP-origin connection path specifically prevents Traefik's SNI
matching from working even though the same cert is correctly registered for connections
arriving via the LoadBalancer path. These have different fixes and are not yet
distinguished.

**One more relevant fact, confirmed from this repo's own
`ansible/playbooks/003-setup-traefik.yml`**: on Rancher Desktop (k3s), Traefik is **not**
installed by this repository's own Helm values at all — "k3s already manages Traefik via
a HelmChart CR. This playbook detects that and skips the helm install." `003-traefik-
config.yaml`'s `ports.websecure.port: 8443` documents what k3s's bundled chart is
expected to already match (for AKS parity), but is not itself applied on Rancher
Desktop. Whatever Traefik is actually running there is whatever k3s's own default
HelmChart CR currently ships — worth confirming directly rather than assumed identical.

**The one diagnostic that would cleanly distinguish (a) from (b), not yet run**: does a
plain host-side `curl`/`openssl s_client -servername authentik.localhost` (reaching
Traefik via Rancher Desktop's own `*.localhost` port-forwarding to the LoadBalancer
Service — the same path a real browser already uses successfully) get the *correct*
certificate, or the same wrong default? If host-side also gets the wrong cert, this is
(a) — a cert-store registration problem, nothing to do with being in-cluster at all. If
host-side gets the right cert and only the in-cluster ClusterIP path gets the wrong one,
this is (b) — something specific to that connection path. Also worth collecting while at
it: `kubectl logs -n kube-system -l app.kubernetes.io/name=traefik` grepped for
`authentik` or TLS-cert-loading errors, and confirmation of which Traefik
(image/chart/version) is actually running.

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
