---
title: PLAN — an API should point at its own documentation
sidebar_label: PLAN — API docs Link header
---

# PLAN — an API should point at its own documentation

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

🔵 **Filed 2026-09-23 from `urb-agents#1423`.** The immediate need is already met at the edge — see [the Cloudflare setup guide](../../../networking/cloudflare-setup.md). This is the UIS-native version, and it is worth doing only because the edge version is per-zone and dashboard-managed.

**Goal**: `uis` emits `Link: <docs>; rel="help"` on an application's API routes, from a value the application declares.

## Why a header rather than the document

The API already carries its documentation URL in two places a reader may never reach: PostgREST's hardcoded `externalDocs`, and `info.description` inside the OpenAPI document. **A header survives where a body is not read.**

| request | status | body |
|---|---|---|
| `Accept: text/html` | `406` | a PostgREST error object |
| `GET /nonexistent_relation` | `404` | `PGRST205` |
| a browser's full `Accept` | `200` | 277 KB of raw JSON |

🔴 **The `406` is the sharpest case**: a tool that asks correctly for HTML gets a clean refusal with no hint that a documentation site exists.

## 🔴 Declared, not derived — and this is the opposite call from `openapi-server-proxy-uri`

That one is **derived**, because `url_prefix` plus the installation's public domain already determine the API's own hostname: the platform knows the answer, and a tenant that had to declare it could declare it wrong.

**This one must be declared.** UIS cannot know a tenant's documentation site — there is nothing to derive it from. ⚠️ And hardcoding it would put one tenant's hostname in the platform, which this repository has already had go NXDOMAIN for four months once.

**The rule worth keeping: derive when the platform knows; accept a key when only the tenant does.**

## Where the value has to live, or a redeploy drops it

⚠️ Passing it as a flag is not enough. A later bare `uis deploy postgrest --app <app>` would render the route without the header, silently — the "reported success, changed nothing" class that `#1411`, `#1413` and `#1415` are all instances of.

🔵 **The per-app secret is already the persistence layer for per-app config the deploy needs** — `PGRST_DB_SCHEMAS` works exactly this way, written by `configure` and read back by the deploy playbook, which already fetches that secret. `docs_url` should follow it rather than invent a second channel.

## The seams

- [ ] `TEMPLATE_CONFIG_KEYS` accepts `docs_url`, and `_build_configure_args` emits `--docs-url`
- [ ] `configure-postgrest.sh` stores it in the per-app secret
- [ ] ⚠️ **and the `no-op` path syncs it** — that path returns before the secret is written, which is exactly how `#1411` happened
- [ ] the ingressroute template renders a `headers` middleware when the value is non-empty, and nothing when it is not
- [ ] a test asserts the header is absent when undeclared, so the feature cannot start emitting a stale or empty `Link`

## Success criteria

- [ ] An application declaring `docs_url` gets the header on `406`, `404` and `200` alike
- [ ] One that declares nothing gets no middleware and no header
- [ ] A bare redeploy preserves it — asserted by redeploying, not by the command exiting 0
