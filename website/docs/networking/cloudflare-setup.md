---
title: Cloudflare advanced topics
sidebar_label: Cloudflare advanced topics
---

# Cloudflare tunnel — advanced topics

This page assumes you've already followed the [main Cloudflare tunnel guide](./cloudflare.md) and have a working tunnel. It covers edge-case behavior that only shows up once a service is actually public: browser CORS, Cloudflare's own bot/challenge mechanisms, caching an API correctly, and what "reachable" does and doesn't promise about uptime.

None of this is needed to get a tunnel working — skip straight to whichever section matches the problem you're actually having.

## Browser access to an API: CORS at the edge

Skip this unless **browser JavaScript** calls an API through the tunnel. Everything else — `curl`, a server, a CLI — is unaffected, because CORS is a browser rule and nothing else enforces it.

### The symptom

The API works from `curl` and fails from a web page, with a console message about a missing `Access-Control-Allow-Origin` header. Measured on a PostgREST service through the tunnel:

```
GET  + Origin      200, NO access-control-allow-origin      <- the browser blocks it
OPTIONS preflight  200, access-control-allow-origin: *
                        NO access-control-allow-methods
                        NO access-control-allow-headers
```

Both halves have to be right. Here the preflight answered but named no methods or headers, and the actual response carried no origin header at all — so even a request that survived the preflight was discarded after it arrived.

### Fix it at the edge, not in the service

**Cloudflare → Rules → Transform Rules → Modify Response Header → Create rule.**

```
If    starts_with(http.host, "api-") or starts_with(http.host, "api.")

Then  Set static:
      Access-Control-Allow-Origin     *
      Access-Control-Allow-Methods    GET, HEAD, OPTIONS
      Access-Control-Allow-Headers    Accept, Accept-Profile, Authorization,
                                      Content-Type, Prefer, Range, Range-Unit
      Access-Control-Expose-Headers   Content-Range, Content-Location
      Access-Control-Max-Age          86400
```

The expression names **no domain and no service** — it matches on the hostname's prefix alone. Adopt the convention and every future API is covered by the rule that already exists.

:::warning Match `api-` and `api.`, never bare `api`
Loosening this to `starts_with(http.host, "api")` looks tidier and is wrong: it also matches **`apidocs.`, `apiary.`, `apikeys.`** and anything else merely beginning with those three letters, each of which would silently receive `Access-Control-Allow-Origin: *`.

Verified on a live zone:

| hostname | CORS header |
|---|---|
| `api-atlas.<your-domain>` | ✅ yes |
| `api.<your-domain>` | ✅ yes |
| `apidocs.<your-domain>` | ❌ no — correctly excluded |
:::

:::tip The rule can exist before the service does
A Transform Rule runs at Cloudflare's edge, so it applies to a hostname whether or not anything is deployed behind it. `api.<your-domain>` returned the headers before that endpoint existed. **A new API gets browser access on day one with nothing further to configure.**
:::

### Pointing an API at its documentation, in the same rule

An API that answers `406` to `Accept: text/html` and `404` with a PostgREST error object gives a reader nowhere to go. A **response header** reaches all of those, because it survives where a body is not read:

```
Link: <https://docs.example.com/>; rel="help"
```

🔵 **`rel="help"` is the registered IANA relation** for *documentation about this resource*. Not `rel="describedby"` — that means a machine-readable description **of the resource itself**, which a human docs site is not.

Add it to the **same** Modify Response Header rule as the CORS headers above. One rule, one expression, and it applies to every response the API produces — including the ones with no body worth parsing:

| request | status | does `Link` arrive? |
|---|---|---|
| `Accept: text/html` | `406`, a PostgREST error object | ✅ |
| `GET /nonexistent_relation` | `404`, `PGRST205` | ✅ |
| a browser's full `Accept` | `200`, raw JSON | ✅ |
| 🔴 an **edge-blocked** request (AI-bot Training, BIC) | `403`, a 25-byte body | ✅ |

🔴 **The last row is the one that justifies the edge placement.** A response-header transform runs before the request would ever reach your cluster, so the header arrives on **responses the origin never sees** — including Cloudflare's own refusals. A blocked reader gets somewhere to go instead of a bare `Your request was blocked.`

:::danger Verify the target resolves before you set it
The first proposed value pointed at a docs hostname that **did not resolve**. A `Link` header aimed at a dead host is worse than no header: it is an authoritative-looking pointer to nothing, and it arrives on exactly the responses where the reader has no other clue.

```bash
curl -sI "https://<your-docs-host>/" | head -1     # want a 2xx or a redirect, not a DNS failure
```
:::

:::info Why the edge and not the service
PostgREST emits no `Link` header and has no setting for one — its three OpenAPI options are `openapi-mode`, `openapi-security-active` and `openapi-server-proxy-uri`, and its `externalDocs` is hardcoded in the source. So it is the edge or the ingress.

⚠️ **The edge is where this API's response headers already live.** The CORS rule above uses the same expression for the same hostnames; putting the documentation pointer beside it keeps one place to look.

🔵 **The ingress is the better long-term home** — it works on `.localhost` and a tailnet too, and it is versioned in git rather than in a dashboard. It needs UIS to learn a per-application `docs_url`, because the platform cannot derive a tenant's documentation site the way it derives the API's own hostname. Tracked as `PLAN-api-docs-link-header`.
:::

:::danger Use **Set**, not **Add**
Cloudflare's *Add* operation *"adds a new HTTP response header … without removing any existing headers with the same name"*, while *Set* *"overwrit[es] its previous value"*. The preflight above **already** returns an `Access-Control-Allow-Origin`, so *Add* produces the header twice — and a browser rejects a response carrying two of them, which looks exactly like the failure you were fixing.
:::

:::info One rule per zone, and it counts against your quota
Transform Rules are **zone-scoped**. This rule covers one domain; a second domain needs its own copy, and the Free plan has **no account-wide version**. The Free plan allows **10 transform rules per zone**, and this is one of them.
:::

:::warning The two lines everyone omits
- **`Allow-Headers`** — PostgREST clients send non-simple headers (`Prefer`, `Range`, `Accept-Profile`). Omit this and the preflight fails, so **the real request is never sent**.
- **`Expose-Headers: Content-Range`** — PostgREST returns row counts there, and **a browser cannot read a response header unless it is exposed**. Omit it and pagination breaks *silently*: the rows arrive, the total never does, and nothing errors.
:::

### Why the service does not do this

Setting `PGRST_SERVER_CORS_ALLOWED_ORIGINS=*` on the deployment produces nothing here, and it is the wrong layer regardless: **an origin is a domain, and a service definition should not contain one.** The same manifest has to work on `.localhost`, on a tunnel and on a tailnet. The edge is where the domain is already known.

:::danger `*` is safe here and is NOT a general recommendation
This applies to an API that **takes no credentials** and is already world-readable to every non-browser client. **CORS is not an access control** — it decides whether a browser lets JavaScript *read* what anyone can already `curl`.

On a service that **does** take credentials, or one behind a login, `*` is wrong: name the origins instead. Do not copy this rule onto a gated service.
:::

## 🔴 `api-` and `api.` are reserved prefixes

Once the rule above exists, **the hostname prefix is a security decision, and it is made when a service is named.**

Calling a service `api-something` gives it a hostname matching the rule, so **any website's JavaScript may read its responses.** Nobody choosing a service name will be reading this page, which is exactly why it is written down here and in the service schema.

### What the risk is, and what it is not

**It is not a credential leak.** `Access-Control-Allow-Origin: *` **cannot be combined with credentials** — a browser refuses to send cookies or HTTP auth to a wildcard origin, and rejects the response if it tries. A cookie-gated service caught by the prefix will not hand an authenticated response to a third-party page.

🔴 **It is an exposure for anything private that needs no credentials to read.** A service protected only by being unadvertised, or one that answers any unauthenticated request with internal data, becomes readable by script from any page on the internet — not just by someone who knows the URL.

### The rule to follow

- **Name it `api-…` or `api.…` when it is a public, browser-facing, credential-free API.** That is what the prefix now means.
- **Do not use the prefix otherwise** — and if an existing service needs renaming, that is cheaper than an exception in the Transform Rule.
- **A gated API is fine under the prefix**: the gate answers `401` to an unauthenticated request, and the wildcard header on a 401 discloses nothing.

## When Cloudflare returns 403 before your cluster sees the request

An edge 403 never reaches the tunnel, Traefik or the application — **nothing in the cluster inspects User-Agent**, so if a request is refused on the basis of one, the refusal is Cloudflare's.

:::danger The WAF screen is usually the wrong place to look
The instinct is *Security → WAF → Managed rules*. **Three separate reports pointed a reader there and there was nothing on it** — the mechanisms that actually produce these 403s live on two other screens entirely, and a reader who checks WAF concludes the block is imaginary.
:::

### The response body tells you which mechanism it was

```
Python-urllib/3.11   403   "error code: 1010"            17 bytes, text/plain
ClaudeBot/1.0        403   "Your request was blocked."   25 bytes, text/plain
```

| Body | Mechanism | Where it lives |
|---|---|---|
| `error code: 1010`, tiny `text/plain` | **Browser Integrity Check** | Security → Settings |
| `Your request was blocked.` | **AI bot policies** | Security → Bots |
| error **1020** with a full HTML block page | a WAF managed or custom rule | Security → WAF |
| `403` **with a `cf-mitigated: challenge` header** | a **Managed Challenge** from a WAF custom rule | Security → WAF → Custom rules |

⚠️ **Bot Fight Mode also emits 1010**, so check that it is off before reading a 1010 as Browser Integrity Check.

🔴 **A challenge and a block both return `403`. Only the header tells them apart:**

```bash
curl -sI "https://<host>/" | grep -i cf-mitigated
# cf-mitigated: challenge   -> a challenge the client failed to solve, not a block
```

⚠️ Without checking that header you will read a challenge as a block and go looking for a blocking rule that does not exist.

:::info This mapping is inference, not measurement
It is consistent with every observed response and with the dashboard's own settings, **but Cloudflare's Security Events log is the authority and it was not opened.** Treat it as a strong first guess that tells you which screen to open, not as proof.
:::

### 🔴 Browser Integrity Check is zone-wide — there is no per-hostname exception

This is the structural fact that makes the obvious remedy impossible. **You cannot exempt one hostname from BIC in the BIC setting.** Cloudflare puts a *"Create configuration rule"* link directly on the setting for exactly this reason: a **Configuration Rule** scoped to the hostname is the only way to turn it off for one API and leave it on everywhere else.

⚠️ So *"add a WAF exception for this hostname"* is not a smaller version of the right answer — **it is not available at all**, and proposing it sends someone to a screen where they will not find the setting they were told to change.

### The AI bot policies are three categories, and blocking one is not blocking AI

The setting most often re-diagnosed as an accident:

| Category | Typical setting | What it covers |
|---|---|---|
| Search | Allow | bots that index for search results |
| **Agent** | **Allow** | *bots that pull information from your site to answer a user's question* |
| Training | **Disallow** | crawlers gathering content to train models |

Measured against a live zone with that configuration:

```
Claude-User/1.0  200   Perplexity-User/1.0  200   ChatGPT-User/1.0  200    <- Agent
Googlebot/2.1    200   OAI-SearchBot/1.0    200   PerplexityBot     200    <- Search
ClaudeBot/1.0    403   GPTBot/1.1           403   CCBot/2.0         403    <- Training
```

🔵 **So disallowing Training does not block live fetches.** When someone asks an assistant to look at your API, the request goes out as `Claude-User` or `ChatGPT-User` — the **Agent** category — and is allowed. *"We block GPTBot"* reads like *"AI tools cannot reach us"*, and that is false.

### Two edge behaviours that make reports contradict each other

**The User-Agent match is case-sensitive and anchored at the start.**

```
Python-urllib/3.11          403      python-urllib/3.11        200   (lowercase)
Python-urllib/3.11 extra    403      myapp Python-urllib/3.11  200   (not first)
Python-urllib                403      PYTHON-URLLIB/3.11        200
```

⚠️ Anyone reproducing a report by retyping the agent string casually will get the opposite result and conclude the first report was wrong.

**Edge-added response headers appear on the 403 too.** A blocked request never reaches the origin, yet the 403 carries `access-control-allow-origin: *` and the rest of the CORS set — because the transform rule runs at the edge.

🔵 That makes a blocked response *look* like it came from the application. It is also positive proof that the CORS headers are the transform rule's work and not PostgREST's.

## A baseline for an API hostname behind a tunnel

A zone can reach production with **one** rule in it and nothing else — no Cache Rules, no Configuration Rules — and nothing will report that as a problem.

:::warning An API behind a tunnel caches nothing by default, and it will not fix itself
Measured on a live zone: **0.01% cached** — 14 kB of 108 MB over 24 hours. **Every one of those bytes crossed the tunnel and hit the origin machine.**

🔴 **PostgREST emits no `Cache-Control`, no `ETag` and no `Last-Modified`.** With no cache headers from the origin, Cloudflare caches nothing by default *and* conditional requests cannot help either. A **Cache Rule with Edge TTL: override origin** is therefore **required to get any caching at all** — not a tuning step. That interaction between PostgREST and Cloudflare is not obvious from either side's documentation.
:::

| | Rule | Why |
|---|---|---|
| 1 | **Cache Rule**, scoped to the API hostname | without it the tunnel carries every byte — **three settings, below** |
| 2 | **Configuration Rule**, if a hostname needs BIC off | the only per-hostname mechanism; BIC itself is zone-wide |
| 3 | **Rate Limiting Rule** | one is included on the free plan |
| 4 | **Response Header Transform** — CORS, and the docs `Link` | already covered above; its headers land on edge-blocked responses too |

### 🔴 The Cache Rule is three settings, and two of them fail invisibly

Deployed and measured on a live zone. **Neither failure is visible from the rules list — both need `curl -D -` to see.**

| # | Setting | Value | What happens if you leave the default |
|---|---|---|---|
| 1 | Cache eligibility | **Eligible for cache** | nothing is cached |
| 2 | Edge TTL | **Ignore cache-control header and use this TTL** → see below | 🔴 **a silent no-op** |
| 3 | Browser TTL | **Bypass cache** | ⚠️ **unpurgeable staleness** |

**Setting 2 — the default is a trap here.** Cloudflare defaults to *"Use cache-control header if present, bypass cache if not"*, and **PostgREST sends no `Cache-Control` at all**. So a rule can be Active, correctly scoped, and cache exactly nothing. It must be told to ignore the origin and use its own TTL.

🔵 **Pick setting 2's TTL from how often the data actually changes, not from a number on a page.** A first value deliberately shorter than the real cadence is a good way to start — short enough that nobody developing against the API is confused while you watch it behave — but it exists **to be raised once you have seen it work**. A zone running 5 minutes while its data changed daily at most was later raised to an hour on exactly that reasoning; the cadence was always the argument, the 5 was scaffolding.

⚠️ **Raising it lengthens every window described on this page** — how long a stale spec is served, how long an outage stays invisible, how long a corrected description keeps serving the old wording.

**Setting 3 — fixing setting 2 creates this one.** The moment responses become cacheable, Cloudflare applies the zone default **Browser Cache TTL of 4 hours**:

```
cache-control: max-age=14400     <- after enabling caching, before fixing Browser TTL
cache-control: no-store          <- with Browser TTL: Bypass cache
```

🔴 **Cache purge does not purge browser caches.** Four hours of unpurgeable staleness on an API developers are actively building against is worse than the problem being solved. **Bypass cache is the right answer for a developer-facing API**: the edge absorbs the load, browsers hold nothing, and everything stays purgeable.

### ⚠️ What these two settings look like from outside, and why it reads as a bug

Settings 2 and 3 together produce a response that looks like a violated control:

```
cf-cache-status: HIT
cache-control: no-store
```

🔵 **Nothing is being ignored here.** Those are the two halves of this one rule, talking to two different caches:

| header | which setting | what it means |
|---|---|---|
| `cf-cache-status: HIT` | 2 | the **edge** stored it, deliberately disregarding the origin |
| `cache-control: no-store` | 3 | the **browser** must not store it |

**That `no-store` is Cloudflare's own instruction to the browser — it is not an origin `no-store` being overridden.** PostgREST never sent one; it sends no `Cache-Control` at all. Confirm from inside the cluster, where Cloudflare is not in the path:

```bash
kubectl -n <namespace> exec deploy/<app>-postgrest -- \
  wget -S -O /dev/null "http://localhost:3000/<view>?limit=1" 2>&1 | grep -i cache-control
# no output — the origin sets no Cache-Control at all
```

### 🔴 The precondition this rule now rests on: the hostname must stay public

Setting 2 says *ignore cache-control*, and it means it.

**The moment anything non-public is served through this hostname, an origin that sets `Cache-Control: no-store` will be ignored** — and a per-user response will be stored at the edge and handed to somebody else. `no-store` is exactly the header you would reach for to prevent that, and it is exactly the header this rule is configured to disregard.

So **this rule is correct only while everything behind the hostname is public.** If that ever changes, setting 2 must change with it — back to *Respect origin*, or with identity in the cache key.

⚠️ **It will not announce itself.** The headers look identical whether the cached body is public open data or somebody's account page. Nothing in the rules list mentions it either.

🔴 **Never apply this rule to a hostname behind [oauth2-proxy](/docs/services/identity/oauth2-proxy)** — a gated hostname serves per-user responses by definition.

### 🔴 Anything you measure through this hostname is the CDN, not the database

A `HIT` returns in tens of milliseconds no matter what the database is doing.

🔵 Two agents once spent an hour reconciling a 103 s reading against an 18 s one. Both had taken "repeat" measurements to check themselves — 0.15 s and 8.37 s — and both repeats were the edge serving a stored copy. Busting the cache, they agreed to within 3%.

**Vary the query string on every request, and confirm you actually missed:**

```bash
curl -s -D - -o /dev/null "https://api-<name>.<your-domain>/<view>?limit=$RANDOM" \
  | grep -i cf-cache-status
# want: MISS (or DYNAMIC) on every single request
```

Distinct query strings are distinct cache entries, which is why a varying `limit` works. ⚠️ **It must be a parameter PostgREST recognises** — an invented name like `?cachebust=` is parsed as a column filter and returns `PGRST100`, a 400 that reads as a broken endpoint. **A timing taken without checking `cf-cache-status` is not a measurement of the origin.**

### What it buys, measured

```
try1  MISS  0.699s     <- origin
try2  HIT   0.036s     <- edge
try3  HIT   0.045s
try4  HIT   0.039s
```

🔵 ~18× faster, and more to the point **zero origin requests after the first**. Distinct query strings are separate cache entries.

### ⚠️ Scoping to one hostname is the entire safety argument, so verify it

A Configuration Rule turning BIC off is a security setting being disabled. **Prove it applies to one hostname and nothing else**, from outside:

| check | want |
|---|---|
| the website host with a blocked User-Agent | still `403` — BIC still on there |
| the website host's `cf-cache-status` | `DYNAMIC` — no cache rule bleeding over |
| the API host with a Training-category bot | still `403` — bot policies untouched |
| the API host with an Agent-category client | `200` — live fetches still work |
| the API host's CORS header | still `*` — the transform rule intact |

🔵 **And the case the whole thread started from**, using the real standard library rather than a spoofed header:

```python
>>> urllib.request.urlopen("https://api-<name>.<your-domain>/...")
200
```

## One tunnel, one apex — what "any domain" does and does not mean

Routing is domain-agnostic: Traefik matches on `HostRegexp(...)`, so `servicename.<your-domain>` reaches the right service with nothing added, whatever `<your-domain>` is.

Two things are still per-apex, and both are easy to assume away:

- **The tunnel's published hostnames.** `*.<your-domain>` covers subdomains of **that apex only**. A second apex needs its own routes and its own DNS records in that zone.
- **Anything behind a login gate.** [oauth2-proxy](/docs/services/identity/oauth2-proxy) derives its callback URL from the request's hostname and scopes its session cookie to a single apex, so **one gate instance serves one apex.** A second apex needs a registered callback URL there *and* a second gate.

So *"point any domain at the cluster and it routes"* is true — and it stops being true the moment the service is gated.

## Challenging scanners without breaking scripted clients

A tunnelled hostname is on the public internet, and **anything on the public internet is scanned.** Measured over 24 hours on one small zone: two addresses accounted for the large majority of traffic, walking a credential-and-config wordlist.

```
/secrets.yml   /etc/.env   /privatekey.key   /api/fs/exec
/debug/pprof/cmdline   /wp-config.php.swp   /actuator/mappings   /core/settings.py
```

✅ **Nothing was exposed** — those paths returned 403 or 404. But the requests reached the origin, and the hosts being walked served only a default placeholder page. **Traffic you serve for nothing is still traffic you serve.**

### 🔴 The obvious switch is the wrong one on a zone with an API

**Bot Fight Mode** is free, one toggle, and **zone-wide with no scoping.** On a zone that also hosts a script-friendly open-data API it blocks non-browser clients aggressively — it would re-break `Python-urllib` and every scripted consumer, **undoing the Configuration Rule** described above. The two settings are in direct conflict and Bot Fight Mode wins, because it applies everywhere.

| option | why not |
|---|---|
| **Bot Fight Mode** | 🔴 zone-wide, unscopeable, re-breaks scripted clients — see [the BIC section](#-browser-integrity-check-is-zone-wide--there-is-no-per-hostname-exception) |
| **block the hosting ASN** | works, and blunt: also blocks legitimate services hosted there, plausibly including AI tooling and preview platforms |
| **rate limiting** | the free plan gives **one** rule. Worth saving until there is real traffic to size it against — and the scanned hosts were not the API |

### ✅ A WAF custom rule, scoped to the hostnames that need it

**Security → WAF → Custom rules.** The free plan allows **five**; this kind of rule is a good use of the first.

```
expression   http.host in {"<placeholder>.<your-domain>" "<other>.<your-domain>"}
action       Managed Challenge
```

🔵 **Managed Challenge rather than Block**, because a scanner and a mistaken human get the same response and only one of them can solve it. It is scoped to the hostnames named, so the API hostname is untouched.

### ⚠️ Verifying a challenge from outside is not obvious

A Managed Challenge returns **`403`** — the same status as a block. The header is the only discriminator:

```bash
curl -sI "https://<challenged-host>/" | grep -i cf-mitigated
# cf-mitigated: challenge
```

**Confirm the API hostname did not get caught in it**, in the same pass:

| check | want |
|---|---|
| a challenged host | `403` **with** `cf-mitigated: challenge` |
| the API host with a scripted client | `200`, no `cf-mitigated` |
| the API host's `Link` and CORS headers | still present |

:::info Do not size a rule from a number you had to join together
Cloudflare's rule preview and a hand-built attribution can disagree by more than an order of magnitude. One reading joined per-IP totals from one panel to hostnames from a **sampled** log list — which makes it the weaker of the two, and it was recorded as such rather than carried forward as measurement.

🔵 **The rule was still correct**: it is scoped, low-risk and reversible, and none of that depended on the disputed number. **Know which of your figures is sampled before you quote it.**
:::

## What a tunnel does not give you: availability

A tunnel makes a machine **reachable**. It does nothing to make it **available**, and the two are easy to conflate once a public hostname resolves and returns 200.

**Write the expectation down where consumers will see it.** Someone building against a hostname cannot tell from the outside whether it is backed by a region or by a Mac on a shelf.

### What actually determines uptime here

| what | in a typical self-hosted install |
|---|---|
| machines serving the app | **one** |
| replicas of the pod | **one** — a restart is a gap, not a failover |
| internet connections | **one**, usually residential |
| power | **one** circuit, usually no UPS |
| people on call | **nobody**, unless someone volunteered |

Add Cloudflare itself as a dependency: the tunnel is a hop the request must survive. 🔵 In exchange you get no inbound ports open, which is the trade worth making — but it is a trade, not a free layer.

### Planned gaps are the common case

Every platform upgrade restarts pods. `./uis deploy` rolls a deployment; a single-replica service is **down for the duration of that roll** — seconds, but not zero. Machine reboots and OS updates are longer. None of this is a fault; it is what one replica means.

### 🔵 The cache hides some of this, and specifically not the part you would want hidden

With the [Cache Rule](#a-baseline-for-an-api-hostname-behind-a-tunnel) in place, repeated identical requests are served from the edge for up to the Edge TTL, so a short origin outage can be **invisible** to a client re-running the same query.

🔴 **It will not cover anyone doing new work.** Distinct query strings are distinct cache entries, so a novel request goes to the origin and fails like any other. The cache protects repetition, not exploration — and a developer trying something new is exactly who notices the outage.

### What to claim, honestly

> **Best effort. No uptime guarantee, no SLA, no on-call.** The service is self-hosted on a single machine and a single home internet connection. Expect brief planned outages during upgrades and occasional unplanned ones from power, network or hardware. Build with retries and backoff, and do not put this service on the critical path of anything that carries its own availability commitment.

⚠️ **Say where it runs, too.** "Home-hosted for now" is information a consumer can act on; "the API" is not.

### Knowing when it is down

Reachability is not monitored by default — nothing in the platform notices an outage on its own. UIS ships [Uptime Kuma](/docs/services/observability/uptime-kuma) for exactly this, and the useful property is that it runs **outside** the cluster it watches: a watchdog on the same machine goes down with the thing it is watching.

**A monitor has to actually exist.** Deploying Kuma and not adding the hostname is the same as not having it.

## DNS edge cases the main guide doesn't cover

These are specific to a domain's DNS history or Cloudflare's auto-create behavior — most setups never hit them.

### DNS auto-create didn't fire

After saving a Published Application Route, Cloudflare *should* automatically create a matching `Type: Tunnel` row in `DNS → Records`. Sometimes it silently skips this — especially for wildcards, apex/root domains, or when conflicting records exist.

**Diagnostic** (from your host):

```bash
# Query Cloudflare's authoritative nameserver directly — bypasses caching
dig +short @sandy.ns.cloudflare.com whoami-public.yourdomain.com
#   Expected: two Cloudflare anycast IPs (e.g., 104.21.x.x and 172.67.x.x)
#   If empty: the wildcard / apex record is missing from Cloudflare's zone
```

If `dig` returns nothing from the authoritative nameserver, the record genuinely doesn't exist in Cloudflare's zone — this is not a propagation issue. Add the record manually:

1. Go to `dash.cloudflare.com → <your-domain> → DNS → Records → Add record`
2. Type: `CNAME`, Name: `*` (or `@` for root), Target: `<tunnel-uuid>.cfargotunnel.com`, Proxy status: **Proxied (orange cloud)**
3. Get the tunnel UUID from `Networks → Tunnels → <your-tunnel> → Overview` tab

Cloudflare's authoritative DNS is instant — within seconds of saving, `dig +short @sandy.ns.cloudflare.com` should return the anycast IPs.

### 404 from Cloudflare edge (despite DNS working)

If `curl https://your-hostname.yourdomain.com/` returns:

```
HTTP/2 404
server: cloudflare
cf-ray: ...
```

…and the headers show `server: cloudflare` (not `server: traefik` or your origin's server), the 404 is from Cloudflare's edge, not your cluster. This means **DNS resolves to Cloudflare, but Cloudflare has no Published Application Route to forward the request through**.

**Diagnostic — confirm traefik would have served it**:

```bash
# Curl traefik directly with the unresolvable hostname as Host header
curl -I -H 'Host: your-hostname.yourdomain.com' http://localhost/
#   If you get 200 (or any non-404 from a route that matches), traefik is fine.
#   The problem is at Cloudflare's published-route layer.
```

**Fix**: go to `Networks → Tunnels → <your-tunnel> → Hostname routes → Published application routes` and verify there's a row covering this hostname. If missing, add it. If you previously added a route in the upper "Your hostname routes" section by mistake — that's a Private route and doesn't serve public traffic — delete it and re-add in the Published Application Routes section.

### Stale DNS records from prior domain owners

If your domain was previously used elsewhere (Squarespace, Wix, one.com, GitHub Pages, etc.), the DNS zone may contain leftover A/CNAME records that proxy traffic to the old origin. These show up as:

- `A` rows at the apex pointing to non-Cloudflare IPs (e.g., Squarespace `198.185.x.x` or `198.49.x.x`)
- `CNAME` rows for subdomains pointing to provider hostnames (e.g., `*.squarespace.com`, `ghs.google.com` for old Google Sites)
- `NS` rows at the apex pointing to a previous registrar's nameservers (cosmetic leftover; the registrar-level NS is what actually matters)

To use the domain with Cloudflare Tunnel, delete the old A/CNAME records that conflict with the tunnel routes. Leave MX records (email), TXT records (verification/SPF), and the registrar-level NS configuration alone.

## Additional resources

- [Cloudflare Tunnel documentation](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/)
- [Tunnel firewall requirements](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-with-firewall/)
- [Adding a domain to Cloudflare](https://developers.cloudflare.com/fundamentals/setup/manage-domains/add-site/)
