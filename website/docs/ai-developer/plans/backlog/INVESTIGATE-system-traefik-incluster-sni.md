# Investigate: Traefik's ClusterIP doesn't present the right certificate for a direct in-cluster strict-TLS connection

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog — the PR #647 fix did NOT resolve it; original root cause claim retracted

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

## Retraction: the `tls.domains` fix (PR #647) did not work, and the original mechanism claim was wrong

imac re-tested PR #647 on `1.6.253`, with a **full Traefik restart** to rule out stale
config/caching, and the IngressRoute carries exactly the shipped config (`tls.domains:
[{main: authentik.localhost, sans: [...]}]`, confirmed), the cert-manager certificate's
own SANs are confirmed correct, no conflicting `TLSStore`/IngressRoute exists — and both
probes still return the identical wrong certificate, with the identical warning in
Traefik's logs, completely unchanged.

**The original mechanism claim below was wrong.** Read the actual Traefik source
(`pkg/provider/kubernetes/crd/kubernetes_http.go`, tag `v3.7.4`) for the exact log line:

```go
// The server name (from a Host(SNI) rule) is the only parameter (available in HTTP
// routing rules) on which we can map a TLS config, because it is the only one
// accessible before decryption... Consequently, when it comes to deciding what TLS
// config will be used, for a request that will match an HTTPS router with no Host
// rule, the result will depend on the _others_ existing routers...
if tlsOptionsName != traefiktls.DefaultTLSConfigName {
    logger.Warn().Msgf("No domain found in rule %v, the TLS option %s cannot be applied", ...)
```

This warning is about **`tlsOptions` resolution** (which `TLSOption` CRD — cipher
suites, minimum TLS version, client-cert requirements — applies to a given SNI), a
completely different Traefik concept from **certificate selection**. It is unrelated to
which certificate gets served. There is also an open upstream issue confirming
`HostRegexp` genuinely doesn't support `TLSOptions` selection at all
([traefik/traefik#11375](https://github.com/traefik/traefik/issues/11375)) — real, but a
different limitation from this investigation's actual symptom.

Read further (`pkg/tls/certificate_store.go`, `pkg/tls/tlsmanager.go`): certificate
selection (`GetBestCertificate`) matches the client's SNI purely against domain keys in
`CertificateStore.DynamicCerts` — a map built from loaded certificates' own content, not
from any router's match rule. And the Kubernetes CRD provider's own certificate-loading
path (`getTLSHTTP`/`getTLS` in `kubernetes_http.go`) keys purely on
`namespace/secretName`, with no dependency on the router's rule shape or on
`tls.domains` at all. On this reading, the real certificate *should* register correctly
from its own SAN content regardless of `HostRegexp` — which means `tls.domains` was
never the relevant mechanism, consistent with imac's observation that adding it changed
nothing. **Why the real certificate still isn't being selected remains genuinely
unexplained from source alone** — this needs live instrumentation (Traefik's own debug-
level logs around certificate/secret loading, not more code reading) to resolve.

## What was previously written here, before the retraction above (kept for history, not current)

The host-side probe came back with the **identical** wrong certificate — ruling out
hypothesis (b) entirely, this has nothing to do with being in-cluster. Traefik's own logs
name the exact mechanism directly:

```
WRN No domain found in rule HostRegexp(`authentik\..+`), the TLS options applied for
    this router will depend on the SNI of each request
```

Traefik builds its SNI certificate store by extracting **literal domain names from each
router's own match rule**. `HostRegexp()` is a pattern, not a name — there is nothing to
extract — so `tls.secretName` on such a router is never actually associated with any SNI
value at all. Every request falls through to the generic default cert, host-side and
in-cluster, every time. This is hypothesis (a): confirmed, not inferred.

A survey of every other `HostRegexp`-routed service in this install found **none of them
declare a `tls:` block at all** — Authentik's own (bug #570) was the first and only place
anyone tried this combination, silently broken since it shipped, until Dex's strict
validation finally exercised it. Traefik version confirmed: `rancher/mirrored-library-
traefik:3.7.4` (k3s's own bundled copy on Rancher Desktop, not this repo's Helm values —
matching `003-setup-traefik.yml`'s own documented behavior).

## `tls.domains` (PR #647) — kept, but no longer believed to be the fix

Left in place (harmless, and `tls.domains` does feed into router-level `TLSOptions`
resolution per source, even though that's not this symptom) but **not re-claimed as the
fix** — see the retraction above. Render-tested and mutation-tested at the time it was
written; that testing was real, the diagnosis behind it was wrong.

## What's actually needed next: live instrumentation, not another source-read

Source-reading alone cannot resolve this further — the certificate-loading and
SNI-matching code paths read as if they should work regardless of router rule shape,
and yet demonstrably don't, live, after a full restart. The next useful step is live
data, specifically:

- Confirm the actual `authentik-server-tls` Secret's `tls.crt` content/age matches
  exactly what the `Certificate` resource's own status most recently reports as issued
  (rules out a stale or mismatched Secret, independent of everything checked so far).
- Traefik's own debug-level logs (`--log.level=DEBUG`, or equivalent via the k3s
  HelmChart CR's values) around startup, grepped for the certificate/secret name —
  Traefik logs its own TLS certificate loading and domain registration at debug level,
  which would show directly whether `authentik.localhost` actually became a key in its
  certificate store at all, rather than inferring it from source.
- Whether Traefik's dashboard/API is reachable at all on this install
  (`ingressRoute.dashboard.enabled` is `false` in this repo's own `003-traefik-config.yaml`,
  though that file doesn't even apply on Rancher Desktop per k3s managing its own
  Traefik — worth checking whether the k3s-bundled one has its API enabled, which would
  let someone query `/api/http/routers`/certificates directly without a log-level
  change at all).

## Scope beyond Rancher Desktop

Not checked against Proxmox or any other platform this repository targets.

## Honest limits of what's in this document

Everything measured above is read from imac's own live report (`urb-agents#2045`) —
exact probe commands and outputs, not summarized from memory. No code has been written
here and no design has been chosen. This document exists to make the finding
discoverable and trackable on its own, separate from the Epinio migration that happened
to surface it, per imac's own explicit recommendation not to fold it into that scope.
