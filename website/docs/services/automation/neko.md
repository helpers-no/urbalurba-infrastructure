---
title: neko
sidebar_label: neko
---

# neko

One real Chromium desktop that **a human and an agent share**. The human watches
and clicks it in a browser tab; an agent drives the same tabs over CDP. Because
the profile persists, a human can log in by hand — 2FA included — and an agent
can then act as that logged-in user without ever holding the password.

| | |
|---|---|
| **Category** | Automation |
| **Deploy** | `./uis deploy neko` — **opt-in only, in no stack** |
| **Undeploy** | `./uis undeploy neko` — keeps the profile volume |
| **Verify** | `./uis verify neko` |
| **Depends on** | Nothing |
| **Required by** | Nothing — consumers opt in |
| **Image** | `ghcr.io/m1k1o/neko/chromium` **pinned to `3.1.5`** |
| **Default namespace** | `browser` |
| **Web view** | `http://neko.localhost` — internal only |
| **CDP** | `neko.browser.svc.cluster.local:9222` — cluster-internal, **unauthenticated** |

## neko or browserless?

Both are browsers. They make opposite trades, and picking the wrong one is the
usual first mistake.

| | **browserless** | **neko** |
|---|---|---|
| Nature | headless, throwaway | interactive, watchable |
| Identity | none — blank every time | **persistent profile; logins survive** |
| Drivers | agents only | **human + agents, same session** |
| Concurrency | many isolated contexts in parallel | **one** shared session, single-writer |
| Reach for it when | rendering JS pages, scraping, synthetic checks | a task needs **the human's own login** |

**The rule:** *many blank browsers in parallel → browserless. One logged-in
browser, shared → neko.*

A login-walled task on browserless has no session to use. A fifty-page parallel
scrape on neko serialises behind one profile and blocks the human out of it.

Cheapest tool that works, in order:

1. **plain HTTP** — the page renders without JavaScript. Free.
2. **browserless** — JavaScript pages, no login needed. Cheap, parallel.
3. **neko** — only when the *human's* login must act. Scarce: one shared session.

Escalate only when the level below fails.

:::danger Read this before you deploy it
neko is not like the other UIS services, and it is opt-in for these reasons.

**CDP is unauthenticated, full browser control — cookies included.** Anything
that can reach port 9222 is logged in as whoever the browser is logged in as.
There is no token and none can be added. It is safe only while the Service stays
private: cluster-internal here, tailnet-only on the reference installation.
**Never** route 9222 through an ingress, a tunnel, or a LAN NodePort.

**The profile volume is a live credential store.** Its blast radius is everything
you log into. It is deliberately **not backed up** — a backup is a second copy of
that blast radius, and re-login is cheap.

**Never run an agent task while a password is being typed.** The human logs in;
*then* the agent acts. An agent driving mid-login can submit the form, navigate
away, or read the field.

**Single writer.** Two drivers on one login collide.
:::

## Deploying

neko is in **no stack**, so `./uis stack install` can never start it. It also
ships commented out of `enabled-services.conf`, so `./uis deploy` skips it. The
only way it starts is naming it:

```bash
./uis deploy neko
./uis verify neko
```

Then open `http://neko.localhost` and log in with the password from the secret:

```bash
kubectl get secret urbalurba-secrets -n browser \
  -o jsonpath='{.data.NEKO_MEMBER_MULTIUSER_USER_PASSWORD}' | base64 -d
```

:::warning The shipped password is a LocalDev default
`LocalDevNekoUser456` keeps Rancher Desktop zero-config. It is a **working
password for a browser holding live sessions** — change it for anything beyond
your own laptop, in `.uis.secrets/secrets-config/00-common-values.env`, then
`./uis secrets apply`.
:::

## How an agent drives it

The recommended path is `@playwright/mcp` pointed at neko's CDP endpoint — the
same mechanism `./uis browserless verify-session` exercises, and proven against
neko's locked-down Chromium on the reference installation.

```bash
claude mcp add neko -- npx -y @playwright/mcp \
  --cdp-endpoint "ws://neko.browser.svc.cluster.local:9222"
```

From inside the cluster. Raw CDP over the websocket, with flattened sessions,
remains the low-level fallback.

Reading pages: **screenshot plus vision beats DOM selectors** on sites that hide
content in shadow DOM.

## Exposure — the part that differs per installation

The web view is HTTP plus a websocket and reaches you through Traefik like every
other UIS service. **WebRTC media cannot use that path** — it needs raw TCP.

neko advertises exactly one `address:port` to the viewer through ICE
(`NAT1TO1` : `TCPMUX`), and the browser connects to precisely that. So the
advertised address must be one the *viewer* can reach, which is a property of
the network, not of the product.

Configure it in `.uis.extend/neko-exposure.yaml`:

| Mode | What it does | When |
|---|---|---|
| `local` (default) | NodePort `32816`, advertised as `127.0.0.1:32816` | Rancher Desktop — zero config |
| `tailscale` | tailscale `LoadBalancer`, advertised at your tailnet IP | viewers on a tailnet |

```yaml
mode: tailscale
advertise_address: "100.97.5.40"   # the tailnet IP this Service will own
hostname: "neko"
```

Cloud exposure is **explicitly out of scope** — not inferred from these two.

:::warning The advertised port must equal the reachable port
In `local` mode the NodePort number and `NEKO_WEBRTC_TCPMUX` are deliberately
the same. A NodePort that renumbered the port would make neko advertise one the
viewer cannot open — and the symptom is a **black screen with everything
reporting healthy**: page loads, pod Ready, `/health` 200.

`./uis verify neko` check E asserts these agree.
:::

## Verifying

```bash
./uis verify neko
```

| | Check | |
|---|---|---|
| A | Web view healthy (`/health` on 8080) | the human's door |
| B | CDP reachable through the Service | the agent's door |
| **C** | **DevTools policy override live, and CDP lists page targets** | **the invisible one** |
| D | Profile volume bound and writable | logins can persist |
| E | Advertised WebRTC port equals the reachable port | media path consistent |

**C is why the playbook exists.** Upstream neko ships
`DeveloperToolsAvailability: 2` in its Chromium policy, under which
`Target.attachToTarget` is **silently refused** and page commands are swallowed.
`/json/version` keeps answering 200, the pod stays Ready, checks A, B, D and E
all pass — and no agent can drive the browser. UIS overrides that one key to `1`
and check C asserts the override is live in the running container.

The verify does **not** prove a human can see video; that needs a real WebRTC
client. Check E proves the advertised values are consistent, not that media
flows.

## Troubleshooting

**The page loads but the screen is black.** The media path, not the web view.
Check that the advertised port equals the reachable one (`./uis verify neko`
check E), and that nothing between you and the cluster blocks that TCP port.

**An agent connects but nothing happens — no error.** The DevTools policy.
Confirm with check C; if the ConfigMap was edited, the pod must restart to
reload the policy.

**CDP refuses to connect at all.** The `cdp` socat sidecar, not the browser.
Chromium binds its debug port to `127.0.0.1` and refuses non-local binds, so
that sidecar is what exposes it:

```bash
kubectl get pod -n browser -l app=neko \
  -o jsonpath='{.items[0].status.containerStatuses[*].name}{"\n"}'
```

Both `neko` and `cdp` must be ready.

**Logins vanished after a restart.** The profile volume. Check it is `Bound` and
writable — a bound-but-unwritable volume means `fsGroup` is not `1000`.

**Everything is gone and I want it gone.** That is the kill switch working:

```bash
kubectl delete pvc neko-profile -n browser
```

`./uis undeploy neko` deliberately does **not** do this — an accidental undeploy
should not log you out of everything.

## Related

- [browserless](./browserless.md) — the other browser, and usually the right one
- [Automation overview](./index.md)
