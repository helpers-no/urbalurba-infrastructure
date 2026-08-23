---
title: browserless
sidebar_label: browserless
---

# browserless

A pool of headless Chromium browsers, available to the whole cluster over a
websocket. Consumers connect with Playwright or the Chrome DevTools Protocol
instead of packaging a browser of their own.

| | |
|---|---|
| **Category** | Automation |
| **Deploy** | `./uis deploy browserless` |
| **Undeploy** | `./uis undeploy browserless` |
| **Verify** | `./uis verify browserless` |
| **Depends on** | Nothing |
| **Required by** | Nothing — consumers opt in |
| **Image** | `ghcr.io/browserless/chromium` **pinned to `v2.38.1`** |
| **Default namespace** | `browser` |
| **Endpoint** | `browserless.browser.svc.cluster.local:3000` — cluster-internal, token-gated |

## Connecting

browserless speaks **two protocols on the same port**, on **different paths**.
Which one you need is decided by your client library, and picking the wrong path
is the usual first mistake — it fails as a connection error, not as a 404.

### Playwright

```javascript
const { chromium } = require('playwright');

const browser = await chromium.connect(
  `ws://browserless.browser.svc.cluster.local:3000/chromium/playwright?token=${process.env.BROWSERLESS_TOKEN}`
);
const page = await browser.newPage();
await page.goto('https://example.com');
console.log(await page.title());
await browser.close();
```

### Chrome DevTools Protocol

Used by Puppeteer, by `connectOverCDP()`, and by most agent tooling.

```javascript
const browser = await chromium.connectOverCDP(
  `ws://browserless.browser.svc.cluster.local:3000?token=${process.env.BROWSERLESS_TOKEN}`
);
```

:::warning `connect()` and `connectOverCDP()` are not interchangeable
`chromium.connect()` needs `/chromium/playwright`. `connectOverCDP()` needs the
root path. Handing either one the other's URL fails at connect time with a
message about the websocket, which reads like the service being down.
:::

### REST, without a client library

For a one-shot render there is no need to speak websockets at all:

```bash
curl -X POST "http://browserless.browser.svc.cluster.local:3000/content?token=$BROWSERLESS_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"url":"https://example.com"}'
```

`/content` returns rendered HTML, `/screenshot` a PNG, `/pdf` a PDF.

## Authentication

Every request needs the token from `urbalurba-secrets` in the `browser`
namespace, as `?token=`:

```bash
kubectl get secret urbalurba-secrets -n browser \
  -o jsonpath='{.data.BROWSERLESS_TOKEN}' | base64 -d
```

In a workload, take it from the secret rather than copying the value:

```yaml
env:
  - name: BROWSERLESS_TOKEN
    valueFrom:
      secretKeyRef:
        name: urbalurba-secrets
        key: BROWSERLESS_TOKEN
```

Requests without a token get `401`. This is the entire access control — see
[Access control](./index.md#access-control).

## Capacity

Defaults are sized for a laptop: **3 concurrent sessions**, **10 queued**, and a
**60 s** timeout per session. A fourth caller waits; the eleventh is rejected.

Sessions are capped because each one is a real Chromium process with its own
memory. Raising `CONCURRENT` on a machine that cannot feed it produces OOMKills
rather than throughput. Change it in `manifests/400-browserless-deployment.yaml`.

## Verifying

```bash
./uis verify browserless
```

Four checks: a real page is rendered end to end, the pool reports itself
available, both protocol endpoints are registered, and anonymous requests are
refused.

The first of those is the one that matters. **browserless can be `1/1 Running`
with a green `/pressure` and still be unable to render anything** — that state
happened during this service's development, when `DATA_DIR` pointed at a
directory that no longer existed behind a volume mount. Health endpoints answered
normally throughout; every render failed. The verify therefore renders a page
carrying a marker and checks the marker comes back.

### The deeper check: a real session

```bash
./uis browserless verify-session
```

`./uis verify browserless` proves the routes **exist**. This proves they **work**:

| | Check | Detects a dead browser? |
|---|---|---|
| A | `chromium.connect()` to the Playwright route, navigate, read the title and DOM back | **yes** |
| B1 | `@playwright/mcp` over CDP: `tools/list` | no — wiring only |
| B2 | `browser_navigate` accepted | no — wiring only |
| B3 | `browser_snapshot` returns content **containing** the marker | **yes** |

:::warning B1 and B2 pass with no browser running
Measured, not assumed: with browserless scaled to zero replicas, `tools/list` and
`browser_navigate` both still pass. `tools/list` is answered by the MCP server
itself, and "navigate accepted" means only that the JSON-RPC call was accepted.

**B3 is the only check on the MCP side that notices a dead browser** — it asserts
the snapshot *contains* the marker, which cannot happen without a live page. If
you are tempted to simplify these checks, B3 is the one to keep.
:::

The distinction matters because the fast verify's endpoint test asserts the
Playwright route answers **400 rather than 404** — that proves a route is
registered and nothing about whether a session can be established through it. A
protocol-version mismatch, an exhausted pool, or a broken context allocation all
leave the route answering 400 while every real session fails.

It is deliberately **not** part of `./uis verify browserless` or `./uis test-all`:
it installs npm packages inside the cluster at run time, so it needs egress to
the npm registry. A dependency on npmjs being up does not belong in the fast
path.

:::note Client version must match
browserless `v2.38.1` ships `playwright-core` **1.56.1** on the default route,
and the check pins the same. A mismatched client fails at `connect()` with a
message about the websocket, which reads like the service being down.
:::

## Troubleshooting

**Every render fails, but the pod is healthy.** Almost always the browser cannot
start while the HTTP server can. Check the logs for `Directory doesn't exist`:

```bash
kubectl logs -n browser -l app=browserless --tail=50
```

**Renders crash on heavy pages.** Chromium uses shared memory for rendering, and
the container default of 64 MB is not enough. The deployment mounts 512 MB at
`/dev/shm` for this reason; if that mount is removed, pages die partway through
with no error from browserless itself.

**You experimented with `kubectl set env` and now nothing authenticates.**
`kubectl set env deploy/browserless --from=secret/urbalurba-secrets` does **not**
undo an earlier `kubectl set env … TOKEN=…`: it *adds* a `BROWSERLESS_TOKEN`
variable and leaves the overridden `TOKEN` in place, so the pod keeps using the
wrong value with nothing to show for it. Redeploy instead:

```bash
./uis undeploy browserless && ./uis deploy browserless
```

That restores `TOKEN` to its `secretKeyRef`. Confirm with:

```bash
kubectl get deploy browserless -n browser   -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="TOKEN")]}'
```

**Callers time out under load.** Check whether the pool is saturated:

```bash
kubectl exec -n browser deploy/browserless -- \
  curl -s "http://127.0.0.1:3000/pressure?token=$TOKEN"
```

`"isAvailable": false` means the queue is full — the pool is working, there is
just more work than three browsers can do.

## Related

- [Automation overview](./index.md)
