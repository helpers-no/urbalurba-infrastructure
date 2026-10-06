---
title: Cloudflare tunnel
sidebar_label: Cloudflare
sidebar_position: 2
---

# Cloudflare tunnel

Expose services on a domain you own through Cloudflare's edge network. The cluster runs a `cloudflared` Deployment that holds an outbound-only connection to Cloudflare — no inbound ports, no public IP, no TLS certificate to create or renew.

Setup is **three commands** plus a one-time step in the Cloudflare dashboard.

## Prerequisites

| Local | Cloudflare |
|---|---|
| The UIS provision-host container running (`./uis start`) | An account with a domain you own (DNS managed by Cloudflare) |
| A cluster active (`uis platform list` shows one as `✓ running (active)`) — rancher-desktop works | A tunnel **created** in the Zero Trust dashboard (you need its token) |

The pipeline is cluster-agnostic — the same commands work against any UIS platform (rancher-desktop, AKS, a Proxmox lab cluster, …) once it's up.

The only credential UIS needs is the tunnel's own token, copied from the dashboard — it's a self-contained string that embeds the tunnel's id and secret, so there's nothing to generate locally. Cloudflare terminates TLS at its edge, so the cluster serves plain HTTP to the connector and no certificate is ever created or copied.

## How many tunnels do you need?

**One cluster, one tunnel: just follow the Quick start below as written.** This is the common case.

**More than one cluster from the same provision-host container** — for example a `test` and a `prod` k3s cluster, switching `CLUSTER_TYPE` between them — needs a separate tunnel (with its own token and its own hostname) per cluster. Routing is configured server-side at Cloudflare, keyed by token: pointing a second cluster at the same token just adds it as another connector on the *same* tunnel, and Cloudflare load-balances across both rather than keeping them separate.

Add `--env <name>` to every command to keep each cluster's token, Deployment and pods in their own slot instead of overwriting each other:

```bash
./uis network init cloudflare --env test     # paste the test cluster's own tunnel token
./uis network up cloudflare --env test
./uis network verify cloudflare --env test

./uis network init cloudflare --env prod     # a separate token for the prod tunnel
./uis network up cloudflare --env prod
./uis network verify cloudflare --env prod
```

Supported names: `dev`, `test`, `prod` (case-insensitive on the command line). Omitting `--env` is the same as always — the two forms don't interfere with each other, so you can run a bare tunnel and one or more named ones side by side if you ever need to.

| | Bare (no `--env`) | `--env test` |
|---|---|---|
| Secret key | `CLOUDFLARE_TUNNEL_TOKEN` | `CLOUDFLARE_TUNNEL_TOKEN_TEST` |
| Local file | `.uis.secrets/service-keys/cloudflare.env` | `.uis.secrets/service-keys/cloudflare-test.env` |
| Deployment / pods | `cloudflare-tunnel` / `app=cloudflared` | `cloudflare-tunnel-test` / `app=cloudflared-test` |

`uis secrets status` reports every named environment's token state alongside the bare one, so you can check all of them at a glance.

Tunnel **creation** is still a manual, one-time step per environment in the Cloudflare dashboard (see Step 1 below) — `--env` only decides which slot UIS stores and deploys each token from.

## Quick start

```bash
./uis network init cloudflare     # 1. interactive wizard, paste the tunnel token
./uis network up cloudflare       # 2. push token to cluster, deploy cloudflared
./uis network verify cloudflare   # 3. confirm DNS + port 7844 + e2e probe
```

Add `--env <name>` to all three if you're setting up more than one tunnel (see above). The sections below walk through what each command does and what output to expect.

### 1. Create the tunnel in the Cloudflare dashboard

Before running any UIS command, create the tunnel in Cloudflare. UIS doesn't call the Cloudflare API for this step — it deploys the in-cluster connector that points at a tunnel you create by hand.

1. Go to the [Zero Trust dashboard](https://one.dash.cloudflare.com) → **Networks** → **Tunnels**. The page is titled **"Tunnels & Mesh"** in the current console.
2. **Create a tunnel** → tunnel type **`cloudflared`** → pick a name.
   - ⚠️ **Not Mesh.** The console offers `cloudflared` and **Mesh** side by side. Mesh is a different product for bidirectional connectivity; you want `cloudflared`.
3. Skip the install instructions for Linux/macOS/Windows — UIS deploys the connector for you. **Copy the tunnel token** (the long string starting with `ey...`) from the install command shown on the page.
   - The wizard's **Continue** button stays disabled with *"No connection detected yet"*. That's expected: the connector is the pod you haven't deployed yet. The tunnel is already saved, so you can leave the install screen and configure routing from the tunnel's own page.
4. Add a **Public Hostname** routing rule. The field is labelled **Hostname** (hint: `e.g., www, blog, api`) and the page shows you the **Full hostname** it will create — check that line reads what you expect before saving:
   - Hostname: `*` (or a specific name like `whoami-public`)
   - Domain: pick your domain
   - Path: **leave empty** — the `^/blog` shown is placeholder text, and empty means "all paths"
   - Service: Type `HTTP`, URL `traefik.kube-system.svc.cluster.local:80`

Routing happens server-side at Cloudflare; the cluster only needs to know the token.

:::danger Read the Service URL back after saving
Saving a route whose origin is a `.cluster.local` address triggers a **"Cloudflare One Client device profile"** popup about Split Tunnels and the `100.64.0.0/10` range. Click **Confirm** — **Cancel aborts the save and silently keeps the previous value**, with no error and a form that looks like it worked.

This applies to **editing an existing route**, not just creating one, and it is the single most expensive mistake on this page: a route that still holds the old origin produces a 502 on every request while the tunnel itself reports Healthy. After saving, re-open the route and read the URL back.
:::

:::tip Automating this step (optional)
Scripting setup for several domains? `uis network create cloudflare --env test --domain urbalurba.eu`
does the above via the Cloudflare API instead, using a vendored OpenTofu module — needs the `tofu`
binary (ships in the provision-host image) and its own, separately-scoped API token (**not** the
tunnel token — see `cloudflare-api.env.template`, created once by hand). `--env` is **required**
here, unlike every other verb below. It shows the plan and asks to confirm before creating
anything (a real, billable, DNS-affecting action — `--yes` skips the prompt), then wires the
result into Step 2's secrets pipeline and stops — it doesn't deploy pods or verify for you;
continue with Steps 3-4 as normal. Details: `networking/cloudflare/tofu/README.md`.
:::

### 2. Run the init wizard

```bash
./uis network init cloudflare              # or: --env <name>
```

The wizard prompts for the **tunnel token** (required) and the **base domain** (optional — needed only for the end-to-end probe in `verify`). It writes two files:

| File | Used by |
|---|---|
| `.uis.secrets/service-keys/cloudflare.env` | `uis network status cloudflare` — for the "configured / running" detection |
| `.uis.secrets/secrets-config/00-common-values.env.template` (patched) | `uis secrets generate` — feeds the token into the cluster's `urbalurba-secrets` k8s Secret |

If the file already exists, the wizard offers three options: skip (keep existing), re-prompt (overwrite), or show (print path + values and exit).

`init` is the one step that needs a real terminal — it reads the token from a prompt and refuses with *"requires an interactive terminal"* when stdin isn't a TTY (piped input, `docker exec` without `-it`, most CI and agent sessions). If you're scripting the rest, run this step by hand and let automation pick up from `up`.

### 3. Deploy the cloudflared pods

```bash
./uis network up cloudflare                # or: --env <name>
```

Two stages:

1. **`uis secrets generate` + `uis secrets apply`** — pushes the token from the local env file into the `urbalurba-secrets` Secret in the cluster. This is the same pipeline every other UIS secret uses.
2. **`ansible-playbook 820-deploy-network-cloudflare-tunnel.yml`** — renders the `820-cloudflare-tunnel-base.yaml.j2` manifest (a Deployment with one `cloudflared` replica) and waits for the pod to reach `Running`. The playbook also runs a final HTTPS probe through your domain if `BASE_DOMAIN_CLOUDFLARE` is set.

The pod registers with Cloudflare's edge within ~15 seconds. After that, any service with a Traefik IngressRoute matching `*.your-domain.com` is reachable on the public internet.

### 4. Verify

```bash
./uis network verify cloudflare            # or: --env <name>
```

Runs five checks:

| # | Check | What it confirms |
|---|---|---|
| 1 | Secrets | The tunnel token is set in the cluster Secret and not a placeholder |
| 2 | Network | DNS resolves `region1.v2.argotunnel.com` and TCP/7844 is reachable (corporate firewalls sometimes block it) |
| 3 | Pods | All `cloudflared` pods are in `Running` phase |
| 4 | Logs | Recent pod logs contain `Registered tunnel connection` |
| 5 | End-to-end | HTTPS probe to `https://<your-domain>` returns 200/301/302/404 (skipped if the domain wasn't set in init) |

A `PASS` on every line means traffic is flowing through the tunnel.

:::tip A 404 is a pass
Check 5 accepts **200, 301, 302 and 404**, and a `404` is the *normal* result on a fresh cluster. It means the request travelled the whole chain — Cloudflare edge → tunnel → connector → Traefik — and Traefik had no IngressRoute matching that hostname. The tunnel is working; there is simply nothing deployed to answer yet.

You can tell whose 404 it is. Traefik's is 19 bytes of `text/plain`:

```
404 page not found
```

Cloudflare's own errors are HTML pages. So a plain-text `404 page not found` is proof the origin was reached.

**What is not a pass:**

| Response | Meaning |
|---|---|
| **502** | The connector is registered but cannot reach the origin. Almost always the Service URL on the dashboard route — check the namespace |
| **530** | Cloudflare cannot reach the tunnel at all — no connector running, or no published application route for that hostname |

To get a real page rather than a 404, deploy a service and use its hostname. Check what is actually routable with `kubectl get ingressroute -A` — the pattern in the IngressRoute is the hostname that will answer, and it is not always the service's name (`whoami` answers on `whoami-public.*`).
:::

### 5. Day-2 commands

```
./uis network status cloudflare   # config + pod state, plus log tail if pods aren't Running
./uis network list                # one-line state across all providers
./uis network down cloudflare     # remove the in-cluster Deployment
```

All three take `--env <name>` too. `down` only deletes the in-cluster `cloudflared` Deployment — the tunnel itself in the Cloudflare dashboard is preserved, so re-running `up` reconnects the same tunnel. To retire a tunnel completely, delete it from Zero Trust → Networks → Tunnels.

The local `cloudflare.env` file is preserved across `down` / `up` cycles so you don't have to re-paste the token. Delete it manually if you want a full reset.

## How traffic flows

Once the tunnel is up:

```
internet user
  ↓
Cloudflare edge (terminates TLS, optionally adds WAF / DDoS rules)
  ↓
cloudflared pod (outbound-only)
  ↓
Traefik IngressRoute (HostRegexp match)
  ↓
your service pod
```

The IngressRoutes don't need to know they're being reached through Cloudflare — they match by hostname (`HostRegexp` patterns), so the same route serves `whoami.localhost`, `whoami.your-device.ts.net` and `whoami.your-domain.com`.

## Troubleshooting

**`uis network up cloudflare` fails at the playbook step with "placeholder value"**

The token from the dashboard wasn't picked up by the secrets pipeline. Verify both files have the real token:

```
./uis network status cloudflare     # confirms the local env file
./uis secrets status                # confirms the master template
```

If the master template still has the placeholder, re-run `./uis network init cloudflare`. The wizard patches both files atomically.

**Pods come up but the domain returns 502**

The connector is registered with Cloudflare and receiving traffic, and cannot reach the origin named in your dashboard route. **Don't guess — the connector logs the origin it is using:**

```
kubectl -n default logs -l app=cloudflared --tail=50
```

(use `app=cloudflared-test` etc. if you're running a named environment)

Look for `originService=`. That is the URL Cloudflare is sending it to, verbatim:

```
ERR error="Unable to reach the origin service … dial tcp: lookup
    traefik.default.svc.cluster.local on <cluster-dns>:53: no such host"
    ingressRule=0 originService=http://traefik.default.svc.cluster.local:80
```

`no such host` from the cluster's DNS means the Service in that URL does not exist. Compare it with what the cluster actually has:

```
kubectl get svc -A | grep -i traefik
```

**By far the most common cause is the namespace.** Traefik runs in `kube-system` on Rancher Desktop, not in `default`, so the route must read `traefik.kube-system.svc.cluster.local:80` (or `:443` if you terminate TLS in the cluster). Check **every** published application route — the wildcard and the apex are separate rules, and `ingressRule=0` / `ingressRule=1` in the log tells you both are affected.

Fix it in the dashboard, not in the cluster: the connector pulls its config from Cloudflare's edge and picks the change up within seconds. **No redeploy is needed** — and re-read the Service URL afterwards, because the Cloudflare One popup aborts the save if you cancel it.

**`./uis network verify cloudflare` says port 7844 is blocked**

Corporate firewalls sometimes block outbound 7844. The tunnel won't establish. Try from a different network, or contact your network team — Cloudflare publishes the [outbound port list](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/configure-tunnels/cloudflared-parameters/network/).

## Cost

The cloudflared connector is free. Cloudflare's free plan covers tunnels, WAF basics, and unmetered DDoS protection. You pay for the domain registration ($10–15/year for most TLDs) and only need a paid Cloudflare plan if you want advanced WAF rules, image optimization, or higher request limits.

## Learn more

- [Cloudflare tunnel official docs](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) — concepts, dashboard reference, advanced routing
- [Cloudflare advanced topics](./cloudflare-setup.md) — CORS for browser-based API access, reserved hostname prefixes, and reading Cloudflare's 403 challenge pages
- [Traefik ingress rules](../contributors/rules/ingress-traefik.md) — how `HostRegexp` routes traffic across localhost, Tailscale, and Cloudflare
