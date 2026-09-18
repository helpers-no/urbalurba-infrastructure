---
title: PLAN — oauth2-proxy as a UIS service
sidebar_label: PLAN — oauth2-proxy service
---

# PLAN — oauth2-proxy as a UIS service

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: Ship `oauth2-proxy` as an ordinary UIS service — `uis enable
oauth2-proxy`, a playbook, a probe, a docs page — so a service can be put behind
a login **without UIS owning a user registry**.

**Last Updated**: 2026-09-18

**Depends on**: `INVESTIGATE-service-exposure-and-auth` (same folder, filed
separately) — that document decides *which* services get protected and whether
exposure is opt-in. This plan only delivers the component. Phases 1–4 can
proceed independently of those decisions; Phase 5 cannot.

(Referenced by name rather than linked, so the two can merge in either order.)

---

## Why a second auth service when Authentik exists

Authentik is already deployed and works. It is also **an identity provider**:
most of its weight — PostgreSQL, Redis, a worker, blueprints, backups, version
upgrades — exists to store and administer users, groups and credentials.

When the people who should get in **already exist** in GitHub, Google or a
corporate IdP, that weight buys nothing: we would be running a directory we do
not want to own, and then keeping it in step with one we do.

oauth2-proxy is a different shape, not a smaller Authentik:

| | Authentik | oauth2-proxy |
|---|---|---|
| Owns the user registry | yes | **no — delegates to a provider** |
| Persistent state | postgres + redis | **none** |
| Components | server + worker + db + cache | **one Deployment** |
| Backup / migration burden | yes | **none** |
| Groups, per-app policy, MFA | yes | no |
| Providers offered at once | many (it is a broker) | **one** |

So the selection rule is not "big or small". It is:

- **We own the users** → Authentik.
- **Someone else owns the users and we keep a list of who may in** → oauth2-proxy.
- **Users must choose between several providers at the login page** → Authentik,
  because federating IdPs is what a broker does and oauth2-proxy explicitly
  cannot (*"the feature to implement multiple providers is not complete"*,
  upstream issue #926).

**Failure mode is also different and better:** oauth2-proxy holds no state, so if
it dies the protected routes fail closed and nothing else notices. Authentik
being down is an outage with a database behind it.

---

## What already exists, and must be reused rather than reinvented

Verified in this repository:

| Existing thing | Consequence for this plan |
|---|---|
| `AUTH10_PROTECTED_SERVICES` in `00-master-secrets.yml.template` | the declarative list already exists — **do not add a parallel config** |
| `078-service-protection-ingressroute.yaml.j2` branches on `type:` `proxy` / `basic` / `oauth2` | add a **fourth branch**, do not fork the template |
| `077-authentik-forward-auth-middleware.yaml` | shows the ForwardAuth Middleware shape to copy |
| `079-basic-auth-middleware.yaml.j2` | shows the per-service generated-middleware pattern |
| `provision-host/uis/services/identity/service-authentik.sh` | the service-definition model, same category |
| `provision-host/uis/services/identity/probes/authentik.yaml` | the probe format |

Traefik's `forwardAuth` is a generic primitive — its Middleware is a single
`address:`. That is why this is an *additional provider behind an existing
interface*, not a second architecture.

⚠️ **Manifest numbers**: `070`–`079` is the auth range and only **072** and
**074** are free. Use **072** — it sorts before `078`, so the middleware exists
before the routes that reference it, and it does not imply a dependency on
Authentik (`073`–`077`).

⚠️ **`website/src/data/services.json` is generated** by
`provision-host/uis/manage/uis-docs.sh`, which GitHub Actions runs (the "JSON
Generation" check, and `generate-uis-docs.yml`). **Never hand-edit it.**

---

## Phase 1 — the service definition

- [ ] **1.1** `provision-host/uis/services/identity/service-oauth2-proxy.sh`.
  `test-metadata.sh` enforces `SCRIPT_ID`, `SCRIPT_NAME`, `SCRIPT_DESCRIPTION`,
  `SCRIPT_CATEGORY`; `service.schema.json` additionally requires `tags`,
  `abstract`, `website`, `summary`, `docs`. Fields worth deciding explicitly:

```bash
SCRIPT_ID="oauth2-proxy"
SCRIPT_CATEGORY="IDENTITY"
SCRIPT_PLAYBOOK="072-setup-oauth2-proxy.yml"
SCRIPT_REMOVE_PLAYBOOK="072-remove-oauth2-proxy.yml"
SCRIPT_CHECK_COMMAND="kubectl get pods -n oauth2-proxy -l app=oauth2-proxy --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REQUIRES=""        # deliberately empty — no database, no cache
SCRIPT_PRIORITY="35"      # before authentik's 40; nothing depends on it
SCRIPT_NAMESPACE="oauth2-proxy"
SCRIPT_DOCS="/docs/services/identity/oauth2-proxy"
```

  **`SCRIPT_REQUIRES=""` is the point of the service** — contrast
  `service-authentik.sh`, which requires `postgresql redis`. If this plan ends up
  adding a dependency, the reason for choosing oauth2-proxy has gone.

- [ ] **1.2** `provision-host/uis/services/identity/probes/oauth2-proxy.yaml`.
  Probe `/ping`, which upstream serves for liveness.
  ⚠️ Write the honest caveat in the probe file, as `authentik.yaml` does: **a
  healthy `/ping` proves the proxy is serving, not that a login works.** A
  misconfigured client secret or a missing `groups` claim passes `/ping` and
  fails every sign-in.
- [ ] **1.3** Do not touch `services.json`. Confirm the generator picks the
  service up by running `bash provision-host/uis/manage/uis-docs.sh` and
  observing the diff, then reverting it — Actions owns the committed copy.

## Phase 2 — manifests

- [ ] **2.1** `manifests/072-oauth2-proxy-deployment.yaml` — Deployment, Service,
  Namespace. **Auth-only mode: no `--upstream`.** Pin the image tag; do not use
  `latest` (see the `cloudflared:latest` finding — an unpinned tag re-pulls on
  every restart and drifts between clusters, against conformance C9).
- [ ] **2.2** `manifests/072-oauth2-proxy-allowlist-configmap.yaml.j2` — the
  email allowlist, one address per line, rendered from the declarative list.
  ✅ Upstream watches this file (`validator.go` calls
  `watcher.WatchFileForUpdates`), so adding a person needs no restart.
  ⚠️ **Verify that specifically with a ConfigMap mount** — a ConfigMap update is
  a symlink swap and fsnotify watchers sometimes miss it. If it does not
  reload, say so in the docs rather than leaving operators to discover it.
- [ ] **2.3** `manifests/072-oauth2-proxy-forward-auth-middleware.yaml` — the
  ForwardAuth Middleware, modelled on `077`:

```yaml
spec:
  forwardAuth:
    address: http://oauth2-proxy.oauth2-proxy.svc.cluster.local:4180/oauth2/auth
    trustForwardHeader: true
    authResponseHeaders:
      - X-Auth-Request-User
      - X-Auth-Request-Email
```

- [ ] **2.4** Decide the cross-namespace question from `INVESTIGATE-service-exposure-and-auth`'s
  Finding 3 **before** writing the Middleware's namespace. Traefik's
  `allowCrossNamespace` defaults to false and this repo does not set it, so a
  Middleware in one namespace cannot be referenced from an IngressRoute in
  another. This blocks `dagster`, `argocd` and `grafana` regardless of which auth
  provider is chosen.

## Phase 3 — secrets

- [ ] **3.1** Add to `00-common-values.env.template` **and**
  `00-master-secrets.yml.template` — both, because the two files are separate
  and drift (see 1.6.120):

```
OAUTH2_PROXY_CLIENT_ID=
OAUTH2_PROXY_CLIENT_SECRET=
OAUTH2_PROXY_COOKIE_SECRET=
```

- [ ] **3.2** 🔴 **`OAUTH2_PROXY_COOKIE_SECRET` must be independent, not derived
  from the client secret.** Deriving it couples them, so rotating the client
  secret silently invalidates every live session. This is a real scar from a
  production deployment elsewhere, not a hypothetical.
- [ ] **3.3** Do **not** add these to `templates/default-secrets.env` as
  working defaults. There is no safe default for an OAuth client secret, and
  that file is tracked in a **public** repository. A placeholder that looks
  configured is worse than an absent one — `822-verify`'s
  `DNS Token: configured` bug was exactly this shape.
- [ ] **3.4** Document which provider the client is registered with, and that the
  redirect URI must be `https://<host>/oauth2/callback`. ⚠️ If the provider only
  permits a root redirect URI, that is a provider-registration problem — **do
  not work around it with a path reroute in the ingress.** That workaround was
  seen in another project and survives proxy swaps as permanent debt.

## Phase 4 — playbooks

- [ ] **4.1** `ansible/playbooks/072-setup-oauth2-proxy.yml` — apply the
  manifests, wait for Running, then **verify more than the pod phase**. The
  1.6.118 lesson: a Running pod is not a working gate. Assert that
  `/oauth2/auth` answers, and fail loudly with the reason if it does not.
- [ ] **4.2** `ansible/playbooks/072-remove-oauth2-proxy.yml`.
- [ ] **4.3** Refuse to deploy when the client id/secret are empty or still
  placeholders — the pattern `820-deploy` task 06 already uses for the tunnel
  token. Better to refuse than to run a gate that cannot authenticate anyone.

## Phase 5 — the declaration: gates, services, stricter

**The driving tenant needs all of this, so none of it is deferrable.** An earlier
draft proposed shipping a single flat allowlist and adding per-path policy later
"when the tenant migrates" — but that tenant *is* v1, so the deferral would have
shipped a version that does not solve the problem it was built for.

```yaml
# .uis.extend/protected-services.yaml

provider:                               # installation-wide; a gate may override
  type: oidc
  issuer: https://idp.example.org

gates:                                  # one oauth2-proxy Deployment each
  - name: staff
    allowed_domains: [example.org]      # anyone with an account at our IdP
  - name: reviewers
    allowed_groups: [reviewers-group]   # 'groups' scope added automatically
  - name: platform-admins
    allowed_emails: [you@example.org]   # named individuals

services:
  - name: handbook
    expose_on: [localhost, cloudflare]
    require_login_on: [cloudflare]
    gate: staff
    stricter:
      - matching: "restricted-"         # PathRegexp — Traefik v3
        gate: reviewers

  - name: dagster
    expose_on: [localhost, cloudflare]
    require_login_on: [cloudflare]
    gate: platform-admins               # NOT staff — see 5.6
    api_routes: ["^/graphql"]
```

- [ ] **5.1** `gates:` is the reusable unit, **because oauth2-proxy's allowlist is
  per-process configuration**. One instance can enforce exactly one answer to
  "who is allowed?". So pods scale with *distinct policies*, not with services —
  put the list on each service and three services sharing one audience become
  three identical pods. The word `gates` rather than `policies` is deliberate:
  it makes the resource cost visible in the config.
- [ ] **5.2** 🔴 **One cookie secret per installation, shared by every gate, with
  one cookie domain.** Not per gate. If gate B cannot read the cookie gate A
  issued, a user already signed in is bounced back to the IdP on crossing into
  B's paths — and if both write the same cookie name with different secrets they
  overwrite each other, which is a login loop that looks like a permissions
  problem. The reference implementation this pattern comes from does exactly
  this, deliberately, *"so one login covers both"*. Take the secret from the
  pipeline; **do not derive it from the client secret** (§3.2).
- [ ] **5.3** `provider:` and `issuer:` belong in the declaration — an earlier
  draft listed only the three secrets and forgot that oauth2-proxy also needs to
  be told *which* provider and issuer.
- [ ] **5.4** ✅ **Infer the `groups` scope.** Any gate with `allowed_groups` gets
  `groups` added to its OIDC scope automatically. Upstream's `--allowed-groups`
  matches nothing at all when the claim is absent, and the reference
  implementation had to set the scope by hand — **inferring it deletes that
  failure mode rather than documenting it.**
- [ ] **5.5** ⚠️ **`allowed_domains` is not a control for every provider.** It
  works when the IdP is domain-bound. For GitHub, user emails may be private or
  arbitrary, so the correct control is organisation or team membership — a fourth
  form the model currently lacks. Decide whether to add `allowed_github_org:` or
  to state that domain-based gates require an OIDC provider.
- [ ] **5.6** 🔴 **A broad gate is the wrong gate for an admin UI, and the
  declaration should make that hard to get wrong.** Dagster OSS has no roles, so
  every person who passes its gate can run `wipeAssets` and
  `launchPartitionBackfill`. "Anyone at the organisation" is right for reading
  internal documentation and wrong for a control plane that can delete
  production run history. Consider requiring an explicit acknowledgement when a
  service with no internal permission model is put behind a domain-wide gate.
- [ ] **5.7** `api_routes` is required, not optional, for any SPA: an expired
  session answers a background `fetch` with a **302 to the provider, not a 401**,
  and browser JS cannot follow a cross-origin redirect to a login page — the call
  fails opaquely or the app parses the provider's HTML as JSON. Upstream's
  `--api-route` is documented as *"No redirect to login will be done. Return 401
  if not."*
- [ ] **5.8** ⚠️ **Revocation is asymmetric and must be measured, not assumed.**
  Removing a service from the list stops the Traefik route being generated. It is
  **not** established that it removes Authentik's application/provider objects,
  which `073`'s blueprints create inside Authentik's database. Verify before
  claiming removal works for `gate: authentik`.
- [ ] **5.9** Decide fail-closed behaviour: what a `require_login_on` host does
  when its gate is not deployed. It should refuse, not serve.

⚠️ **`expose_on:` is NOT owned by this plan** — see
`PLAN-service-exposure-opt-in`. It appears in the example because the two fields
share a file, and because `require_login_on` must be a subset of `expose_on`,
which one of the two generators has to assert.

## Phase 6 — verification, on the tester

Nothing below can be checked without a cluster. `whoami` is the natural subject:
it is already the single entry in `AUTH10_PROTECTED_SERVICES`.

- [ ] **6.1** Anonymous page load → redirected to the provider, **not a bare
  401**. 🔴 **This is the one genuinely unknown mechanic.** Traefik's
  `forwardAuth` passes the auth server's non-2xx response through to the client,
  so pointing it at `/oauth2/auth` may yield a 401 instead of a sign-in redirect.
  Establish the working combination empirically before writing it into docs.
- [ ] **6.2** Sign in as an allowlisted address → reaches the service.
- [ ] **6.3** Sign in as a **non**-allowlisted address → 403, and the page says
  why. Upstream returns `ErrorPage(…, http.StatusForbidden, "Invalid session:
  unauthorized")` with generic default wording; `--custom-templates-dir`,
  `--banner` and `--footer` are the knobs. **Decide whether generic is
  acceptable** — "403 Forbidden" with no explanation generates support traffic.
- [ ] **6.4** `POST /graphql` with an expired cookie → **401, not 302**
  (proves 5.2).
- [ ] **6.5** Add an address to the ConfigMap → takes effect **without a
  restart** (proves 2.2's caveat one way or the other).
- [ ] **6.6** Delete the oauth2-proxy pod → protected routes **fail closed**,
  and unprotected routes keep working.
- [ ] **6.7** `.localhost` access to a protected service still works with no
  login — **the regression that would matter most**.
- [ ] **6.8** 🔴 **Attempt the path-gate bypass.** A `stricter:` rule matches on
  the request path, so any *other* path that reaches the same content — a route
  alias, a trailing-slash variant, a static asset path, an `/index.html` form —
  is served by the permissive gate instead. Try to reach a restricted page by a
  path that does not contain the pattern. **A separate hostname has no such
  surface**; if the bypass works, that is the honest answer instead.
- [ ] **6.9** Sign in as someone in the group, cross from a permissive path to a
  `stricter:` path, and confirm **no second login** (proves 5.2).

## Phase 7 — docs and tests

- [ ] **7.1** `website/docs/services/identity/oauth2-proxy.md`, matching
  `SCRIPT_DOCS`. Must state, prominently:
  **the allowlist is what makes this a control.** Upstream's `--email-domain`
  accepts `*` — documented as *"Use `*` to authenticate any email"* — and most
  quickstarts show exactly that. With `*` and a public provider, this component
  converts "anonymous" into "anyone with a Google account" and is close to no
  protection at all. Write the footgun down.
- [ ] **7.2** State plainly that this is **authentication, not authorization**.
  Every person a gate admits is equal. For Dagster that means every admitted
  person is a full admin, because Dagster OSS has no roles — auth changes *who*,
  never *what*.
  ⚠️ **Do not describe a read-only Dagster as if it were available.** The viewer
  tier would come from `dagsterWebserver.enableReadOnly`, which deploys a
  *second* webserver — and `360-dagster-ingressroute.yaml` has one route, so that
  instance has no Service, hostname or IngressRoute today. It is unbuilt work in
  no plan, and earlier drafts of this plan referred to it as though it existed.
- [ ] **7.3** Tests. `test-metadata.sh` covers the required `SCRIPT_*` fields
  automatically. Add static assertions for the things that would silently
  regress: the image tag is pinned and not `latest`; the cookie secret is not
  derived from the client secret; `default-secrets.env` gained no OAuth
  placeholder. Follow the house pattern in `test-metadata.sh` and include a
  **positive control** so a broken assertion cannot pass silently.
- [ ] **7.4** Update `AUTH10_PROTECTED_SERVICES`'s comment to document the new
  `type:` and what each type is for.

---

## Out of scope

- **Deciding which services get protected**, and opt-in versus opt-out exposure.
  That is that INVESTIGATE's Q1–Q4.
- **Replacing Authentik.** Both should exist; they answer different questions.
- **Multiple providers at one login page.** Upstream cannot, and wanting it is
  the signal to use Authentik.
- **GraphQL operation-name filtering at the ingress.** The UI sends queries as
  `POST /graphql` — same method and path as the destructive mutations. Any
  separation means parsing bodies and allowlisting operation names, which fails
  open on anything unanticipated.

## Success criteria

1. `uis enable oauth2-proxy` then deploy brings up a working gate with no
   database and nothing added to `SCRIPT_REQUIRES`.
2. `whoami` is reachable after signing in as an allowlisted address, refused with
   a comprehensible page otherwise, and **still open on `.localhost`**.
3. All seven Phase 6 checks pass on the tester.
4. The docs name the `*` footgun and the authentication-is-not-authorization
   limit before describing any happy path.
