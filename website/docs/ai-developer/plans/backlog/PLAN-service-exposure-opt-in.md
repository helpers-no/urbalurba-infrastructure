---
title: PLAN — a service is not public unless it says so
sidebar_label: PLAN — exposure opt-in
---

# PLAN — a service is not public unless it says so

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: Make public reachability a property a service **declares**, instead of a
consequence of a wildcard route existing. Today every IngressRoute in the
repository is published the moment a wildcard tunnel is created, whether or not
anyone intended it.

**Last Updated**: 2026-09-18

**Answers**: Q1 of `INVESTIGATE-service-exposure-and-auth` (same folder) —
*"is exposure opt-in or opt-out?"* Terje's answer, 2026-09-18: **opt-in.**

**Sibling**: `PLAN-service-oauth2-proxy` handles *authentication*. This plan
handles *reachability*. They are different axes and neither substitutes for the
other — a service can be reachable and unauthenticated (the current default), or
authenticated and not publicly reachable (the desired default for admin UIs).

---

## Why this is separate from the auth work, and why it matters more

Two Dagster webservers were found answering anonymous GraphQL on the public
internet, on two different tunnels, neither deliberately. The auth plan puts a
login in front of named services. **It does not change what happens to the other
twenty-four.**

If `PLAN-service-oauth2-proxy` ships alone, the two services that migrate get
gates and everything else stays exactly as exposed as it was when the incident was
found — because the default remains "routable and unprotected unless somebody
remembers to add it to a list". That default is what caused both incidents. Auth
is not the fix for it.

## The root cause is one regex

Every route in `manifests/` matches like this:

```yaml
- match: HostRegexp(`pgadmin\..+`)
```

`.+` matches **any** domain. So the moment a Cloudflare wildcard route points a
domain at Traefik, `pgadmin.<that-domain>` resolves and serves — without anything
in this repository having said that pgadmin should be public.

`manifests/360-dagster-ingressroute.yaml` shows how little intent has to do with
it. Its own header says `INTERNAL ONLY` and it carries
`urbalurba.io/description: "… no public exposure"`, and then matches
`HostRegexp(\`dagster\..+\`)`. The author knew, wrote it down, and the platform
had no way to act on it.

## 🔵 The fix is cheap, and does not require abandoning the wildcard tunnel

**Exposure is enforced in Traefik, not at Cloudflare.** The wildcard tunnel sends
every hostname to Traefik; Traefik then decides what it has a route for. Make the
routes host-specific and an undeclared hostname simply matches nothing:

```yaml
# declared: expose_on: [localhost]
- match: Host(`pgadmin.localhost`)

# declared: expose_on: [localhost, cloudflare]
- match: Host(`handbook.localhost`) || Host(`handbook.example.org`)
```

Then `pgadmin.example.org` arrives at Traefik, matches no route, and gets the
catch-all — **not pgadmin**. The wildcard tunnel can stay exactly as the
documentation describes it, and nothing is published that was not declared.

The data needed is already in the secrets pipeline:

```
BASE_DOMAIN_LOCALHOST=localhost
BASE_DOMAIN_CLOUDFLARE=your-domain.com
```

So a declaration of `expose_on: [localhost, cloudflare]` renders to two `Host()`
matchers with no new configuration concepts.

## The two fields, and why they are not one

`INVESTIGATE-service-exposure-and-auth` Finding 2 observes that the existing
`domains:` field is declared and ignored, and proposes making it mean what it
says. An earlier draft of the auth plan instead proposed replacing it with
`require_login_on:`. **Those were two different proposals and they contradicted
each other.** The resolution is that they are two different questions:

| Field | Question | Example |
|---|---|---|
| `expose_on:` | where is this service **routable at all**? | `[localhost, cloudflare]` |
| `require_login_on:` | where does it additionally **require a login**? | `[cloudflare]` |

**Invariant: `require_login_on` must be a subset of `expose_on`.** Requiring a
login on a domain the service is not reachable on is always a mistake, and the
generator should refuse it rather than silently produce a route nobody can hit.

This also expresses the developer requirement directly: `expose_on: [localhost,
cloudflare]` with `require_login_on: [cloudflare]` means *open locally,
authenticated publicly* — which is what `domains:` looked like it promised and
never delivered.

---

## Phase 1 — decide the default, and write it down

- [ ] **1.1** **The default for a service that declares nothing is
  `expose_on: [localhost]`.** Local development keeps working untouched; nothing
  reaches the internet without a declaration. This is the whole plan in one
  sentence and everything else implements it.
- [ ] **1.2** Decide what happens to a request for an undeclared hostname.
  Today it falls through to `nginx-root-catch-all`
  (`020-nginx-root-ingress.yaml`, `PathPrefix(/)` at `priority: 1`), so it
  returns the nginx landing page rather than failing. ⚠️ **That means the cluster
  answers every hostname with a 200 instead of failing closed** — decide whether
  that is wanted. A 404 is more honest; the landing page is friendlier to a
  developer who mistyped.
- [ ] **1.3** Record the rule in
  `website/docs/contributors/rules/ingress-traefik.md`, which today teaches
  `HostRegexp` as the recommended pattern and is therefore the source of the
  problem.

## Phase 2 — the generator

- [ ] **2.1** Extend the declarative list (see `PLAN-service-oauth2-proxy` for
  the file's location and shape) with `expose_on:`.
- [ ] **2.2** Generate `Host()` matchers per declared domain instead of
  `HostRegexp(name\..+)`.
- [ ] **2.3** Assert the subset invariant and refuse on violation, naming the
  service and both lists. Do not warn and continue.
- [ ] **2.4** ⚠️ **`uis auth apply`-style removal must work here too**: removing a
  domain from `expose_on` has to remove the matcher. An apply that only ever adds
  makes un-exposing impossible, which is the same theatre problem as an
  allowlist that cannot revoke.

## Phase 3 — migrate the 24 existing routes

- [ ] **3.1** Convert each hand-written IngressRoute to a declaration. **24
  routes**, counted by parsing each document for a `HostRegexp` match rather than
  grepping filenames — a file-level grep matches comments and produced a much
  rosier first count.
- [ ] **3.2** 🔴 **Every one of them defaults to `expose_on: [localhost]` unless
  there is a reason otherwise**, and the reason goes in the declaration. Two
  candidates for public are known — a documentation site and a public demo
  endpoint. Everything else is an admin UI.
- [ ] **3.3** Delete the intent-only annotations, or make them generated from the
  declaration. Leaving both means two sources of truth, one of which does nothing.

## The gate/service desync — ops-dev, 2026-09-19, and it dates this plan

Found by reading a running ingress before any second domain existed, which makes it the first evidence for this plan that is neither hypothetical nor historical:

```
ungated   atlas-postgrest            HostRegexp(`api-atlas\..+`)      pattern
ungated   dagster                    HostRegexp(`dagster\..+`)        pattern   priority 10
GATED     dagster-oauth2-protected   Host(`dagster.urbalurba.com`)    literal   priority 20
GATED     dagster-oauth2-callback    Host(`dagster.urbalurba.com`)    literal   priority 30
```

**The services that are open match patterns. The objects that protect them match literal hosts.** Today the gate outranks the pattern for the host it names, so the gated host is gated — verified. Point a **second apex domain** at the cluster and `dagster.<new-domain>` matches the pattern, does *not* match the gate, and is served **unauthenticated**.

🔴 **The property that makes this dangerous is not the exposure, it is the silence.** The declared host stays correctly gated, so every check, monitor and runbook entry keeps passing. A new door opens beside the locked one. And the trigger — pointing another domain at the cluster — would be done for an unrelated reason by someone with no cause to think about this service.

### Two candidate fixes, and only one of them is free

**A — broaden the gate** (`Host(...)` → `HostRegexp(`dagster\..+`)`), so the gate follows the service wherever it is served. Architecturally attractive: *"point any domain at the cluster and Traefik will route."*

⚠️ **A does fail closed, but it does not work.** The gate wins on priority, so nothing is served anonymously — and then:

- **oauth2-proxy derives `redirect_uri` from the request's own hostname** (measured: the same config produced `dagster.localhost` and `dagster.urbalurba.com` callbacks). GitHub requires the redirect to match a **registered callback URL**, so a new host gets `redirect_uri_mismatch` at the provider.
- **`cookie_domain` is a single apex.** A session cookie scoped to `urbalurba.com` is never sent to another apex, so even with the callback registered the sign-in cannot complete.

So A converts a silent exposure into a **broken service on every new domain**, until someone registers a callback URL (max 10 per app) *and* runs a gate instance per apex. That is a real answer to the architectural wish: **routing is domain-agnostic; a gated service is not, and cannot be without multi-apex gate support.**

**B — narrow the service** (`HostRegexp(`dagster\..+`)` → declared hosts). A new domain then serves **nothing** until a human opts in. **This is simply what this plan already proposes**, arrived at independently from the other direction.

🔵 **B is the fix. A is a thing to know about**, because it is the obvious move and it looks free.

### ⚠️ Do not "fix" `api-atlas` by symmetry

It has the same pattern and **no gate to desynchronise from**. A published API reachable under a second name is the intent. The defect is the *disagreement between two matchers*, not the pattern itself.

### Shipped ahead of the plan: detection, in 1.6.126

`072-setup-oauth2-proxy.yml` task 11b queries the live ingress after gating and warns when a **pattern** route serves a service the gate matches **literally**, naming the route and the hosts actually covered.

It **warns rather than refuses**, deliberately: the broad route belongs to the service, and every gated service has one today, so refusing would make the gate undeployable for the only thing it gates. **It becomes a refusal when this plan narrows those routes** — at which point a broad route beside a gate is a bug rather than the norm. It loops over the declaration, so an ungated service is never examined.

## The test ladder — Terje, 2026-09-18

Three rungs, each isolating one layer, so a failure names its own cause:

| rung | state | what it proves |
|---|---|---|
| **1** | `.localhost`, no tunnel, no gate | the app and Traefik alone |
| **2** | tunnel up, open, no gate | the tunnel path alone |
| **3** | tunnel up **and** gate | the gate on a real https host |

Terje's words: *"a test should first test .localhost, then bring up the tunnel and test it when it is open, and then finally add the oauth2-proxy and test again."*

**Adopted, because skipping a rung already cost three rounds.** The oauth2-proxy gate was tested at rung 1 for three releases, and one limitation could not be found there at all: on plain-http `.localhost` the sign-in is *structurally* incapable of completing — `--cookie-secure=true` issues a `Secure` CSRF cookie the browser discards, and the derived `redirect_uri` is an `https://…localhost/…` URL nothing serves. That sat as an unresolved caveat for three rounds and became obvious the moment the gate ran at rung 3.

### ⚠️ Rung 2 is the condition this plan exists to prevent, and that tension is not resolved by ignoring it

Rung 2 — tunnel up, no gate — **is** an anonymous admin UI on the internet. That is `urb-agents#1224`, and the maintainer's standing order is the opposite: gate first, tunnel second, so that state never exists.

Both are right, and the resolution is not to pick one:

- **Rung 2 must be short, deliberate and announced.** It is a measurement, not a deployment. Someone is watching it, it is entered on purpose, and it is closed by moving to rung 3 rather than by being forgotten.
- **It must never be the resting state.** The failure mode is not "twenty minutes of exposure", it is "nobody remembered to climb to rung 3".
- 🔵 **`expose_on` makes rung 2 cheap and safe to leave** — with opt-in exposure, a host reaches rung 2 only because a declaration says so, and rung 2 for one service is not rung 2 for the other twenty-four. **That is an argument for this plan, not an exception to it.**

On 2026-09-18 rung 2 lasted about twenty minutes on one host, was entered by the operator knowingly, and was closed by the operator asking for the gate. That is the shape it should always have.

## Phase 4 — verification

- [ ] **4.1** With a wildcard tunnel active and one service declared
  `expose_on: [localhost]`, confirm `<service>.<public-domain>` does **not**
  serve that service.
- [ ] **4.2** Confirm a service declared `expose_on: [localhost, cloudflare]`
  does serve on both.
- [ ] **4.3** Confirm `.localhost` still works for every service with no
  declaration at all — **the regression that would matter most**.
- [ ] **4.4** Remove `cloudflare` from a service's `expose_on`, apply, and confirm
  the public hostname stops serving (proves 2.4).
- [ ] **4.5** A static test asserting **no manifest contains
  `HostRegexp(name\..+)`** once migration is done, so the pattern cannot return.
  Include a positive control, per the house pattern in `test-metadata.sh`.

## Phase 5 — stop the documentation teaching the problem

- [ ] **5.1** `networking/cloudflare-setup.md` Step 3 instructs the operator to
  create a route with subdomain `*`. With this plan that becomes safe, because
  Traefik no longer answers for undeclared hostnames — **but the doc should say
  that explicitly**, or the next reader will assume the wildcard is the exposure
  decision. It is not; the declaration is.
- [ ] **5.2** `ingress-traefik.md` currently recommends `HostRegexp` for all
  services *"to enable multi-domain access without updating IngressRoutes"* —
  which is precisely the behaviour being removed. Rewrite it, and say why.

---

## Out of scope

- **Authentication.** `PLAN-service-oauth2-proxy`. A declared-public service with
  no gate is still unauthenticated, deliberately — `whoami-public` exists to be
  exactly that.
- **Tailscale exposure.** The same declaration should eventually cover the tailnet,
  but Tailscale's UIS integration has its own open investigation and doing both at
  once would couple two migrations.

## Success criteria

1. A service with no declaration is reachable on `.localhost` and **nowhere else**,
   with a wildcard tunnel active.
2. No manifest contains `HostRegexp(name\..+)`, enforced by a test.
3. Removing a domain from a declaration removes the reachability.
4. The Cloudflare guide no longer reads as though `*` is the exposure decision.

## The honest limit of this plan

It stops *UIS-managed* routes from being published by accident. It does not stop
anything else in the cluster from being reachable — an application that ships its
own IngressRoute with a permissive matcher is outside this mechanism, and ArgoCD
deploys applications that do exactly that. **A lint over all IngressRoutes in the
cluster, not just the ones UIS generates, is the complete answer**, and it is not
in this plan.
