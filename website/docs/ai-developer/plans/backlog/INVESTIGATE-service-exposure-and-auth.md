# Investigate: exposure is a property of the tunnel, not of the service — and exactly one service has a login

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: Decide how a UIS service becomes reachable from the internet, and what
stands in front of it when it does. Today the answer is "the Cloudflare wildcard
route publishes everything, and exactly one service has a login."

**Last Updated**: 2026-09-18

**Related**: [INVESTIGATE-service-authentik-user-config](./INVESTIGATE-service-authentik-user-config.md) ·
[ingress-traefik rules](../../../contributors/rules/ingress-traefik.md) ·
[Cloudflare setup](../../../networking/cloudflare-setup.md)

---

## What prompted this

A Dagster webserver was found answering anonymous GraphQL on the public internet
with 41 callable mutations, including `wipeAssets`, `deleteRun`,
`launchPartitionBackfill` and `reportAssetCheckEvaluations` — the last of which
lets a stranger report an asset check as *passing*. Open-source Dagster has no
authentication at all; that is upstream's position, not a misconfiguration.

Two separate deployments were exposed, on two different tunnels. Neither was
exposed deliberately.

**The developer experience that has to survive any fix:** a developer runs
`./uis start`, opens `dagster.localhost`, and it works with no login. That is
correct and must not regress. The problem is only what happens when the same
cluster gets a public hostname.

---

## Finding 1 — the mechanism already exists, and one service uses it

UIS has a declarative protection mechanism ("auth10"). In
`00-master-secrets.yml.template`:

```yaml
AUTH10_PROTECTED_SERVICES: |
  - name: whoami
    type: proxy
    description: "Whoami test service"
    domains: ["localhost", "tailscale", "cloudflare"]
    application_slug: "whoami-app"
```

It drives two templates:

| Template | Generates |
|---|---|
| `078-service-protection-ingressroute.yaml.j2` | the protected IngressRoute + middleware reference |
| `073-authentik-service-protection-blueprint.yaml.j2` | the matching Authentik application/provider |

and already branches on three `type` values: `proxy` (Traefik ForwardAuth),
`basic` (Traefik basicAuth), `oauth2` (service does its own flow).

**So the machinery is built, wired end to end, and protects exactly one service:
`whoami`.** `dagster`, `pgadmin`, `argocd`, `grafana` and the rest are simply not
in the list. This investigation is mostly about why that list never grew.

## Finding 2 — `domains:` is declared and then ignored

The declaration models exposure *per service, per domain* — which is precisely
what the requirement needs. The template does not honour it:

```jinja
- match: HostRegexp(`{{ service.name }}\..+`)
```

`.+` matches every domain. Protecting a service protects it on `.localhost` too.
**There is currently no way to express "open on `dagster.localhost`, authenticated
on `dagster.example.com`"** — the data model promises the distinction and the
generated route erases it.

This is the single change that makes the developer-experience requirement
expressible. Everything else in this document is downstream of it.

**⚠️ RESOLVED 2026-09-18, and not the way this finding first proposed.** An
earlier draft said "make `domains:` mean what it says". A draft of the auth plan
instead said "replace it with `require_login_on:`". Those are different
proposals and they contradicted each other. The resolution is that exposure and
authentication are **two questions and therefore two fields**:

| Field | Question |
|---|---|
| `expose_on:` | where is this service **routable at all**? |
| `require_login_on:` | where does it additionally **require a login**? |

with `require_login_on` required to be a subset of `expose_on`. `expose_on:` is
owned by `PLAN-service-exposure-opt-in`; `require_login_on:` by
`PLAN-service-oauth2-proxy`. **Do not implement the original wording of this
finding** — reinterpreting one field to mean both is what made the two documents
disagree.

## Finding 3 — cross-namespace middleware blocks the services outside `default`

`078` generates routes in `namespace: default` and references
`authentik-forward-auth` in `default`. The services needing protection are not
there:

| Service | IngressRoute namespace |
|---|---|
| `whoami` | `default` ← the one that works |
| `pgadmin` | `default` |
| `dagster` | `dagster` |
| `argocd` | `argocd` |
| `grafana` | `monitoring` |

Traefik's `allowCrossNamespace` defaults to **false** and this repo does not set
it — `git grep allowCrossNamespace` returns nothing. So a `dagster`-namespace
IngressRoute cannot reference a `default`-namespace Middleware.

**This blocks `dagster`, `argocd` and `grafana` specifically.** It is *not* the
whole explanation for the list having one entry, and an earlier draft of this
document overstated it: `minio`, `pgadmin` and `redisinsight` are all in
`default`, where a `default` Middleware would resolve fine, and they are
unprotected too. So the primary reason is simply that nobody populated the list
— cross-namespace is an additional obstacle for the services outside `default`,
and it has to be solved before those can be added at all.

Confirm on a live cluster before designing around it — the check is
`kubectl -n kube-system get helmchartconfig traefik -o yaml` plus a deliberate
cross-namespace middleware reference that either resolves or does not.

Three ways out, to be chosen not assumed:

1. Enable `allowCrossNamespace` in the Traefik provider config — one setting,
   widens what any IngressRoute may reference.
2. Replicate the Middleware into each namespace — no global switch, N copies to
   keep in step.
3. Generate the protected IngressRoute **in the service's own namespace** with a
   Middleware alongside it — self-contained per service, more template work.

## Finding 4 — the intent is already written down and nothing enforces it

`manifests/360-dagster-ingressroute.yaml` says, in its own header and annotation:

```yaml
# Traefik IngressRoute for the Dagster webserver — INTERNAL ONLY.
annotations:
  urbalurba.io/description: "Dagster webserver — internal operator UI, no public exposure"
```

and then matches `HostRegexp(`dagster\..+`)`, which the Cloudflare wildcard
publishes. **The author knew, recorded it, and the platform had no way to act on
it.** An annotation is documentation; it is not a control.

The platform runbook states the same rule in prose — *"Anything with a permissive
IngressRoute is public by default"* — but that lives in the private platform
repo, while the UIS guide that instructs the operator to type `*` does not
mention it.

## Finding 5 — the documented happy path publishes every route in the cluster

`networking/cloudflare-setup.md` Step 3 instructs two published application
routes: subdomain `*` and the apex, both pointing at Traefik. Against this
repo's manifests:

Counted by parsing each IngressRoute document for an actual `middlewares:`
block, not by grepping filenames — a file-level grep matches comments, and that
mistake produced a much rosier first count:

```
28 IngressRoute documents with a HostRegexp match
 4 carry a middlewares: block, and only ONE of those is authentication:
     078-service-protection-ingressroute.yaml.j2  → authentik-forward-auth  (auth)
     076-authentik-ingressroute.yaml.j2           → authentik-csp-upgrade   (CSP header)
     091-gravitee-ingress.yaml                    → gravitee-portal-strip   (path strip)
24 carry no middleware at all: grafana, otel, minio, minio-console, s3,
     whoami-public, rabbitmq, enonic, temporal, temporal-api, gravitee-gw,
     openwebui, argocd, litellm, uptime-kuma, openmetadata, dagster,
     browserless, neko, nextcloud, onlyoffice, backstage, pgadmin, redisinsight
```

**So exactly one service is behind authentication at the edge — `whoami`, via the
`078` template — and everything else is open.** `minio` and `temporal` in
particular are *not* protected; `087-temporal-ingressroute.yaml` carries a
comment saying it should be (*"authentik-forward-auth middleware if the cluster
is exposed to the internet"*), which is the same intent-without-enforcement as
Finding 4.

"Unprotected" here means *no forward-auth at the edge* — several have their own
application login. But:

**⚠️ Those application logins are seeded from `templates/default-secrets.env`,
which is tracked in this PUBLIC repository with fixed literal values** for
`DEFAULT_ADMIN_PASSWORD`, `DEFAULT_DATABASE_PASSWORD`,
`DEFAULT_AUTHENTIK_BOOTSTRAP_PASSWORD` and `DEFAULT_REDIS_PASSWORD`, and
`first-run.sh` seds exactly those into every fresh install. A login is not a
control when its password is published. Any design that leans on
"the app has its own login" has to answer this first.

## Finding 6 — Dagster has a real server-side read-only mode, and the chart exposes it

Verified against the version this repo pins (**dagster 1.13.19**), not `master`:

- `dagster-webserver --read-only` exists. Help text: *"Start server in read-only
  mode, where all mutations such as launching runs and turning schedules on/off
  are turned off."*
- It flows into `WorkspaceProcessContext(read_only=...)`, and
  `get_user_permissions(read_only)` returns `VIEWER_PERMISSIONS`, in which
  `LAUNCH_PIPELINE_EXECUTION`, `DELETE_PIPELINE_RUN`,
  `TERMINATE_PIPELINE_EXECUTION`, `RELOAD_REPOSITORY_LOCATION` and
  `STOP_RUNNING_SCHEDULE` are all `False`.
- The GraphQL mutations are gated **server-side** — `mutation.py` decorates them
  `@require_permission_check(...)` and calls `assert_permission_for_job` /
  `assert_permission_for_location`. **It is not UI button-hiding.**
- The Helm chart already supports it:
  `dagsterWebserver.enableReadOnly: false` — *"Deploy a separate instance of the
  webserver in --read-only mode"* — with its own ingress block
  `readOnlyDagsterWebserver`.

So a two-instance split is available without writing anything: a full webserver
and a read-only one, each with its own hostname and its own exposure decision.

**It is not a substitute for auth.** The catalogue, run history and run logs stay
readable, and run logs can carry connection strings or credential-bearing error
text from ingest stdout. That has not been examined and should be.

---

## Finding 7 — problems found reviewing this document (2026-09-18)

Recorded here rather than silently fixed, because three of them are things this
investigation asserted and should not have.

**🔴 Authentication was being conflated with exposure.** Most of this document is
about *protection*, while the incident that prompted it was about *reachability*.
They are different axes: a service can be reachable and unauthenticated (today's
default), or authenticated and not publicly reachable (what admin UIs want). Q1
asks the exposure question and the auth plan does not answer it. Split into
`PLAN-service-exposure-opt-in`.

**⚠️ Path-based gating is bypassable in a way host-based gating is not.** Gating a
subset of a host by path regex means any *other* path reaching the same content
— a route alias, a trailing-slash variant, a static asset path — is served by
the permissive gate instead. A separate hostname has no such surface. Any plan
using a path match needs an explicit test that attempts the bypass.

**⚠️ Revocation may be asymmetric between gate types.** Removing a service from
the declarative list stops the Traefik route being generated. It does **not**
obviously remove the Authentik-side application/provider objects created by
`073`'s blueprints, which live in Authentik's database. Unverified, and it
undermines any claim that "removal works" for Authentik-gated services.

**⚠️ Domain-based allowlisting does not work for every provider.** "Anyone at our
organisation" is expressible as an email domain only when the IdP is
domain-bound. For GitHub, user emails may be private or arbitrary, and the
correct control is organisation or team membership. A design offering only
domains, groups and addresses has a gap for that provider.

**⚠️ Fail-closed behaviour is unstated.** What a `require_login_on` host does when
its gate is not deployed has to be decided, not discovered.

**🔵 And one correction to Finding 6's implied plan:** the read-only Dagster
webserver is referred to elsewhere as though it were an available UIS service. It
is not. `360-dagster-ingressroute.yaml` has a single route, and a read-only
instance needs `dagsterWebserver.enableReadOnly` plus its own Service, hostname
and IngressRoute. That is unbuilt work in no plan.

## The questions this has to answer

**Q1. Is exposure opt-in or opt-out?** Today a service is public because a
wildcard exists, not because anyone said so. Proposal: a service is not publicly
routable unless it declares it. This is the decision everything else hangs on.

**Q2. Should `*` remain the documented default?** It is what both incidents had
in common. Alternative: teach a named hostname, and make the wildcard an
explicit opt-in whose blast radius the doc states.

**Q3. Does `domains:` become real?** See Finding 2. Without it, "open locally,
authenticated publicly" cannot be expressed and the developer experience and the
security requirement are in direct conflict.

**Q4. What is the auth ladder, and what is each rung for?**

| Rung | Mechanism | New components | Candidate use |
|---|---|---|---|
| 0 | `*.localhost`, no tunnel | — | development — keep exactly as is |
| 1 | tailnet-only | none (Tailscale already deployed) | admin UIs: dagster, pgadmin, argocd |
| 2 | `type: basic` (already in `078`) | one Secret | stop-gap measured in days |
| 3 | oauth2-proxy as ForwardAuth | one Deployment, no DB | public, named humans |
| 4 | Authentik (already deployed) | postgres + redis + server + worker | production SSO, groups, per-app policy |

Rungs 1, 2 and 4 already exist in this platform. Only rung 3 is new.

**Q5. Is oauth2-proxy worth adding at rung 3?** The integration point is
`forwardAuth`, a generic Traefik primitive whose Middleware is a single
`address:`. Swapping providers is one field; `078`, the `protected_services`
list and the generated routes are unchanged. So it is a lighter provider behind
an interface that already exists, not a second architecture.

**⚠️ It is only a control if the allowlist is set, and the default is that it is
not.** The documented `--email-domain` option reads *"authenticate emails with
the specified domain (may be given multiple times). Use `*` to authenticate any
email"* — and `*` is what most quickstarts show. Unrestricted, oauth2-proxy
converts "anonymous" into "anyone with an account at the provider", which for a
public IdP is close to no control at all. The restrictions, verified in the
upstream docs:

| Option | Documented as | Character |
|---|---|---|
| `--authenticated-emails-file` | *"authenticate against emails via file (one per line)"* | an explicit list of people; provider-agnostic |
| `--github-org` / `--github-team` | *"restrict logins to members of this organisation"* / *"…of any of these teams (slug) or (org:team)"* | membership already administered elsewhere |
| `--email-domain=<domain>` | as above, without `*` | only a control if that domain is a tenant we own |
| `--allowed-group` | *"Restrict login to members of a group or list of groups"* | OIDC groups claim |

Two mechanics worth knowing before designing around it, both read from upstream
source rather than docs:

- **The rejection is server-side and produces a 403.** In the OAuth callback:
  `if p.Validator(session.Email) && authorized { …success… } else {
  p.ErrorPage(rw, req, http.StatusForbidden, "Invalid session: unauthorized") }`.
  The default page wording is generic; `--custom-templates-dir`, `--banner` and
  `--footer` are the knobs for a useful "your address is not on the list".
- **The emails file is watched, not read once** — `validator.go` calls
  `watcher.WatchFileForUpdates(...)`, so adding a person is editing a file with
  no restart. Verify this specifically with a ConfigMap mount, since a ConfigMap
  update is a symlink swap that fsnotify watchers sometimes miss.

**🔴 One instance supports one provider.** Upstream: *"the feature to implement
multiple providers is not complete"* (issue #926). So "let people sign in with
Google **or** GitHub" is not an oauth2-proxy feature — federating several IdPs
behind one login page is what an identity broker does, which is to say it is the
Authentik requirement. That makes the constraint a useful decision rule rather
than a limitation: one provider acceptable → oauth2-proxy suffices; a choice of
providers required → Authentik.

Against it otherwise: authentication only, no groups and no per-service policy;
a real IdP application per environment (client id + secret, a secrets-pipeline
item); and a cookie domain spanning the hostnames so one sign-in covers
subdomains. Give it an independent session secret — deriving one from the client
secret couples them, so rotating the client secret silently invalidates every
live session.

**🔵 A pattern worth copying, from a project that has run this in production
since June 2026 against an enterprise OIDC provider:** two proxy instances
behind one router, one permissive and one requiring a group, sharing a derived
cookie secret so a single sign-in satisfies both gates and every replica agrees
with no shared session store. There it selects by URL slug; the analogue here is
per-host — one strict middleware, one permissive, and the route picks which.
That turns "which services may ever be public" into two middlewares and a
per-service field, rather than twenty-four individual decisions.

**🔴 And the trap that bears directly on Dagster:** an expired session answers a
background `fetch` with a 302 to the provider, not a 401. Browser JS cannot
follow a cross-origin redirect to a login page, so the call fails opaquely or
the app parses the provider's HTML as JSON. Dagster's UI is an SPA talking
`POST /graphql`, so it would hit this on every session expiry. The fix is
`--api-route`, documented as *"Requests to these paths must already be
authenticated with a cookie… No redirect to login will be done. Return 401 if
not."*

**Q6. Does authentication actually solve Dagster?** Only partly, and this should
be stated wherever it is offered. Dagster OSS has no users and no roles, so any
authenticated visitor is a full administrator. Auth changes *who* can call
`wipeAssets` from "anyone" to "anyone who can log in". It does not create a
viewer tier — `--read-only` does, and only by running a second instance.

**Q7. What do run logs contain?** They are readable in the UI and ingest stdout
can carry credentials. This bears on how much the read-only instance may be
exposed, and has not been checked.

---

## Deliberately out of scope

**GraphQL operation-name filtering at the ingress.** The UI sends ordinary
queries as `POST /graphql` — the same method and path as `wipeAssets`. Blocking
POST breaks the UI; allowing POST allows the mutations. Separating them means
parsing GraphQL bodies and allowlisting operation names, which is brittle and
fails open on anything unanticipated. Not to be built.

## Suggested sequence

1. **Q1 and Q3 first** — make exposure opt-in and make `domains:` real. Until
   the declaration is authoritative, no choice of auth product prevents a
   recurrence, because the wildcard overrides whatever a service declares.

   ⚠️ **This ordering was consciously overruled on 2026-09-18, and the reason is
   recorded rather than hidden.** A tenant migrating onto UIS needs
   authentication to move at all, so `PLAN-service-oauth2-proxy` is being built
   first. **Nothing has made the sentence above false.** Shipping the auth plan
   alone gives gates to the two services that migrate and leaves the other
   twenty-four exactly as exposed as they were when this investigation was
   opened. `PLAN-service-exposure-opt-in` is the one that closes the incident,
   and it is filed separately so that neither plan can be mistaken for the
   other.
2. **Confirm Finding 3** on a live cluster and pick one of its three options.
   This unblocks adding any service outside `default` to the list.
3. **Populate `AUTH10_PROTECTED_SERVICES`** with all 21, each with an explicit
   rung. Most admin UIs land on rung 1 and need no new components.
4. **Then** decide oauth2-proxy versus Authentik per service — by which point it
   is one field, not an architecture.
5. Separately: the public-repo development-default credentials (Finding 5) and
   the run-log content question (Q7). **Q7 is still unexamined** — nobody has
   looked at what ingest stdout puts into run logs, and it is what decides how
   exposed even a read-only instance may be.
