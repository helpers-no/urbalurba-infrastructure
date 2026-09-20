---
title: oauth2-proxy
sidebar_label: oauth2-proxy
---

# oauth2-proxy

Login gate using an external identity provider

| | |
|---|---|
| **Category** | Identity |
| **Deploy** | `./uis deploy oauth2-proxy` |
| **Undeploy** | `./uis undeploy oauth2-proxy` |
| **Depends on** | None |
| **Required by** | None |

| **Default namespace** | `oauth2-proxy` |

## What It Does

oauth2-proxy authenticates visitors against an external identity provider (GitHub, Google, or any OIDC issuer) and allows through only the people on a configured list. It runs as a Traefik ForwardAuth gate, holds no user records and no persistent state, so it fits the case where the user directory belongs to someone else. It provides authentication only — everyone admitted is equal, with no groups or per-service permissions.

## When to use this, and when to use Authentik

Both put a login in front of a service. They answer different questions, and picking the wrong one costs a migration rather than a config change.

| | **oauth2-proxy** | **Authentik** |
|---|---|---|
| **Who owns the users** | Someone else — GitHub, Google, a corporate IdP | You do |
| **What UIS stores** | A list of email addresses. No users, no passwords, no groups | A user directory: PostgreSQL, Redis, a worker, blueprints |
| **What it answers** | *Is this person allowed in?* | *Who is this person, and what may they do?* |
| **Granularity** | One gate, one answer. Everyone admitted is equal | Groups, per-application permissions, roles |
| **Providers** | **One per instance** (upstream issue #926) | Several, and the user picks |
| **Operational weight** | A stateless pod. Nothing to back up or migrate | A database and a cache to run, back up and upgrade |

**Choose oauth2-proxy when** the people who should get in already have accounts somewhere else and you only need to keep a list of who those people are. A small team putting an internal dashboard behind a login is the case it fits.

**Choose Authentik when** you need any of: users who exist only here, groups or per-service permissions, a choice of provider at sign-in, or self-service account management.

:::tip The honest rule of thumb
If you find yourself wanting to say *"these people can see it but only those people can edit it"*, you have outgrown this service. It authenticates; it does not authorize. Everyone who gets in gets the same thing.
:::

They also coexist. Nothing stops Authentik protecting one service while this gate protects another.

## What this depends on — and one limit that surprises people

**No Cloudflare dependency.** It works over any ingress: a tunnel, a tailnet, or plain `.localhost`.

:::warning One gate instance serves ONE apex domain
This is the constraint that feels like a Cloudflare dependency and is not. Two independent mechanisms produce it:

1. **The callback URL is per hostname.** oauth2-proxy derives `redirect_uri` from the *request's own* hostname, so a visitor arriving at `dagster.example.org` sends a callback for that host. Providers only accept a **registered** callback URL, so an unregistered hostname fails at the provider with `redirect_uri_mismatch`.
2. **The session cookie is scoped to one apex.** `cookie_domain` covers `example.com` and everything under it. A cookie scoped to one apex is **never sent** to another, so even with the callback registered the sign-in cannot complete.

So gating hosts under a second apex needs a **second registered callback URL** (GitHub allows up to 10 per app) **and a second gate instance**. Adding hostnames under the *same* apex is just another entry in `hosts:`.
:::

:::info A sign-in on plain-http `.localhost` cannot complete
`--cookie-secure=true` issues a `Secure` CSRF cookie, which a browser discards over plain http, and the derived `redirect_uri` is an `https://…localhost/…` URL nothing serves. Use `.localhost` to check that a service is *reachable*; test the login itself on a real https hostname.
:::

## Registering the provider application

Worked here against GitHub. Other providers differ in the UI, not in the shape.

### 1. Create an **OAuth App** — not a GitHub App

:::danger This is the mistake that costs the most, and nothing errors
GitHub offers both, they look interchangeable, and **only an OAuth App works.** [GitHub's own documentation](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-user-access-token-for-a-github-app) states that for a GitHub App *"the user access token does not use scopes. Instead, it uses fine-grained permissions."*

oauth2-proxy asks for `user:email read:org`. A GitHub App **ignores that parameter**, so the token is not guaranteed to carry the email the allowlist matches on — sign-in succeeds at GitHub and the gate then admits nobody, with no error pointing at the cause.

**Check the client id prefix. `Ov23li…` is an OAuth App and is what you want. `Iv23li…` is a GitHub App — delete it and start again.**
:::

Create it at **Settings → Developer settings → OAuth Apps → New OAuth App**.

:::tip Register it to an organization, not to yourself
A personal OAuth app **cannot be rotated by anyone else and does not transfer**. The credential behind a production login gate should not depend on one person being available.
:::

### 2. Add one callback URL per gated host

```
https://<host>/oauth2/callback
```

One entry per hostname you gate, because the redirect is derived per request. GitHub accepts **up to 10** per app.

:::danger Leave wildcard matching OFF
GitHub can match a callback URL across subdomains, which would cover every host in one line. Their own warning is that it *"allows an attacker to send authorization codes to any subdomain or subdirectory of the callback URL."* Behind a wildcard tunnel, where undeclared hostnames already reach the cluster, that is a real exposure and not a theoretical one.

⚠️ **Apps created before 2026-08-03 with a single callback URL have wildcard matching enabled implicitly**, to preserve the old behaviour. So *"add one callback URL"* can silently produce a wildcard-enabled app — **check the toggle rather than assuming.**
:::

### 3. Put the credentials in the secrets pipeline

The provider gives you **two** values. The gate needs **three**.

```bash
# .uis.secrets/secrets-config/00-common-values.env.template
OAUTH2_PROXY_CLIENT_ID=          # from the provider
OAUTH2_PROXY_CLIENT_SECRET=      # from the provider
OAUTH2_PROXY_COOKIE_SECRET=      # yours — openssl rand -base64 32 | head -c 32
```

- `OAUTH2_PROXY_COOKIE_SECRET` is **not** supplied by the provider. It must be exactly **16, 24 or 32 bytes** (AES-128/192/256) or the pod will not start, and it must be **independent** of the client secret — deriving one from the other means rotating the client secret silently invalidates every live session.
- **No quotes, and no trailing newline.** These values are substituted verbatim. A secret carrying a stray newline fails at the provider as `invalid_client`, which is indistinguishable from a wrong secret. Copy from a file with `$(tr -d '\r\n' < file)` rather than pasting.

```bash
./uis secrets generate && ./uis secrets apply
```

Verify by **length**, which catches the newline and reveals nothing:

```bash
kubectl get secret urbalurba-secrets -o jsonpath='{.data.OAUTH2_PROXY_CLIENT_SECRET}' | base64 -d | wc -c
```

### 4. Declare who may pass, and what is gated

```yaml
# .uis.extend/protected-services.yaml
provider: github
cookie_domain: "example.com"        # the APEX of the hosts below
allowed_emails:
  - person@example.com              # PRIMARY VERIFIED address at the provider
protected:
  - name: dagster
    namespace: dagster
    service: dagster-dagster-webserver
    port: 80
    hosts: ["dagster.example.com"]
    api_routes: ["^/graphql"]       # required for single-page apps
```

```bash
./uis deploy oauth2-proxy
```

## Deploy

```bash
# Deploy oauth2-proxy
./uis deploy oauth2-proxy
```

## Verify

```bash
# Quick check
./uis verify oauth2-proxy

# Manual check
kubectl get pods -n oauth2-proxy -l app=oauth2-proxy
```

## Configuration

<!-- MANUAL: Service-specific configuration details -->

Two files, and the split matters: **credentials are secrets, the rest is not.**

| What | Where | Overwritten by an update? |
|---|---|---|
| Client id, client secret, cookie secret | `.uis.secrets/secrets-config/00-common-values.env.template` | No — it holds your values |
| Provider, allowlist, cookie domain, gated services | `.uis.extend/protected-services.yaml` | No — copied once if missing |

:::info An update will not refresh either file's guidance
Both are yours, so a new release cannot edit them. If the comments in your copy disagree with this page, **this page is current.**
:::

### The allowlist is what makes this a control

`allowed_emails` is a list of **named addresses**, not a domain pattern. There is no `@example.com` form, and that is deliberate: oauth2-proxy accepts `--email-domain=*`, which upstream documents as *"use `*` to authenticate any email"*. With a public provider that converts *anonymous* into *anyone with a GitHub account*. **UIS never offers it.**

:::warning `--whitelist-domain` is not an allowlist
It is the flag someone skimming for a domain allowlist will find first, and it is an **open-redirect guard** — it controls which hosts the gate may redirect *back* to after sign-in. It grants nobody access and denies nobody access. The only thing deciding who gets in is `allowed_emails`.
:::

Each address must be the **primary verified** address on the provider account. Providers return every address they hold; the gate matches only the one flagged verified-and-primary, so a secondary address produces a *successful* sign-in followed by a refusal — which reads like a broken gate.

### `api_routes` — required for single-page apps

Browser JavaScript cannot follow a cross-origin redirect to a login page, so an XHR that receives a 302 either fails opaquely or parses the provider's HTML as JSON. Paths listed in `api_routes` answer **401** instead of redirecting.

The gate itself cannot tell API paths apart — ForwardAuth sends its own subrequest, so the gate sees `GET /` whatever the visitor asked for. UIS therefore generates a **separate higher-priority Traefik rule** per pattern. Dagster's UI needs `^/graphql`.

### Rotating a credential

```bash
# 1. edit the value in 00-common-values.env.template
./uis secrets generate && ./uis secrets apply    # 2. update the cluster Secret
./uis deploy oauth2-proxy                        # 3. roll the pod
```

:::warning Step 3 is not optional, and older releases did not do it for you
The credentials reach the pod through `secretKeyRef`, and **Kubernetes does not restart a pod when a referenced Secret changes.** Before 1.6.126 the pod template was identical between runs, so there was nothing to roll: every surface reported success and the gate kept serving with the **old** credential until it was revoked at the provider — at which point the gate broke with nothing connecting it to the rotation.

From 1.6.126 the pod template carries the Secret's `resourceVersion`, so the deploy rolls it and then **fails if the serving pod is still on an older version.** On an earlier release, restart it yourself:

```bash
kubectl -n oauth2-proxy rollout restart deployment/oauth2-proxy
```
:::

## Undeploy

```bash
./uis undeploy oauth2-proxy
```

## Troubleshooting

<!-- MANUAL: Common issues and solutions -->

Every symptom below has been seen on a real cluster.

| Symptom | Almost always |
|---|---|
| Sign-in succeeds, then **everyone is refused** | A **GitHub App** instead of an OAuth App (`Iv23li…`), or an address that is not the account's primary verified one |
| `invalid_client` at the provider | A trailing newline in the client secret, or the wrong app |
| `redirect_uri_mismatch` | That hostname has no callback URL registered — the redirect is derived per host |
| The sign-in **loops** with no error | `cookie_domain` is not the apex of the host being visited. A cookie for the wrong domain is discarded silently |
| An XHR gets a **302** and the UI breaks | Its path is not in `api_routes` |
| The pod will not start | Cookie secret is not 16, 24 or 32 bytes |
| A **401 with no `Location`** where a login was due | A middleware pointing at `/oauth2/auth` instead of `/`. `/oauth2/auth` answers 401 **by design** — it exists for nginx's `auth_request`, and Traefik has no `error_page` to turn it into a redirect |
| A rotated credential **has no effect** | The pod was not rolled — see *Rotating a credential* |
| `undeploy` printed success, host returns **500** | Fixed in 1.6.125. An orphaned route pointed ForwardAuth at a deleted gate |
| Namespace stuck at `Terminating` after undeploy | Ordinary Kubernetes finalisation. It is empty throughout and clears in a few minutes |
| The `state` parameter carries `http://…` for an https host | **Expected behind a tunnel, and not a downgrade.** See below |

```bash
kubectl -n oauth2-proxy logs -l app=oauth2-proxy --tail=50
```

The gate logs each check. `No valid authentication in request. Initiating login.` is a visitor being sent to the provider — the normal path, not an error.

:::info `state` carrying `http://` is not a finding
On a tunnelled host the post-login return target inside the `state` parameter reads `http://<host>/` even though the visitor arrived over https. **It has been reported once as a security finding and it is not one** — Cloudflare upgrades the final redirect, so nothing travels in clear.

The cause is which hop the gate can see: TLS terminates at Cloudflare's edge, and the connection from the tunnel connector to Traefik is plain http. `--reverse-proxy=true` is set, so the gate honours `X-Forwarded-*` where it receives them, but the ForwardAuth subrequest reflects that inner hop.

🔵 Written down so nobody rediscovers it. ⚠️ **It would matter on an ingress that is genuinely plain http end to end** — there the return target is accurate rather than cosmetic, and the sign-in should not be exposed that way in the first place.
:::

:::warning Removing the gate reopens the hosts. It does not close them.
`./uis undeploy oauth2-proxy` deletes the routes the gate added, which **uncovers each service's own route** — so those hosts are anonymous again, exactly as before the gate existed. To drop a login while keeping the gate running, set `protected: []` and re-deploy instead.
:::

## Learn More

- [Official oauth2-proxy documentation](https://oauth2-proxy.github.io/oauth2-proxy/)
- [GitHub: creating an OAuth App](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/creating-an-oauth-app)
- [GitHub: callback URLs and wildcard matching](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps)
- [Authentik](/docs/services/identity/authentik) — the other choice, when you own the users
