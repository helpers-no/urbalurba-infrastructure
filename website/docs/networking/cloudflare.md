---
title: Cloudflare tunnel
sidebar_label: Cloudflare
sidebar_position: 2
---

# Cloudflare tunnel

Expose services on a domain you own through Cloudflare's edge network. The cluster runs a `cloudflared` Deployment that holds an outbound-only connection to Cloudflare — no inbound ports, no public IP, no manual TLS certificates.

The novice path — from a fresh provision-host container to a service reachable on the public internet — is **three commands** plus a one-time dashboard click.

## Prerequisites

| Local | Cloudflare |
|---|---|
| The UIS provision-host container running (`./uis start`) | An account with a domain you own (DNS managed by Cloudflare) |
| A cluster active (`uis platform list` shows one as `✓ running (active)`) — rancher-desktop works | A tunnel **created** in the Zero Trust dashboard (you need its token) |

This guide assumes rancher-desktop as the target cluster — that's what was verified for this round. The pipeline is cluster-agnostic, so the same commands work against AKS once the platform is up.

### There is no key or certificate to create

The tunnel token is the only credential. It's a self-contained string that embeds the tunnel id and its secret, so you copy it from the dashboard rather than generating anything:

| Not needed | Why |
|---|---|
| `cloudflared tunnel login`, `cert.pem`, a per-tunnel credentials file | That's the older certificate-based model. UIS deploys the token-based connector; the old path survives only under `networking/cloudflare/legacy/` |
| A TLS certificate | Cloudflare terminates TLS at its edge — the cluster serves plain HTTP to the connector |
| A Cloudflare API token | UIS never calls the Cloudflare API. The DNS record is created by the Public Hostname rule you add in the dashboard |
| An SSH key | The connector dials out to Cloudflare over HTTPS/QUIC |

`CLOUDFLARE_DNS_TOKEN` in `00-common-values.env.template` is the one thing that looks like a counter-example. It's optional and unrelated to the tunnel: only `ansible/playbooks/utility/u01-add-domains-to-tunnel.yml` reads it, for bulk DNS automation. `uis network verify cloudflare` prints whether it's set and never requires it, so leave the placeholder alone unless you run that playbook.

:::caution One tunnel per cluster
Routing is configured server-side at Cloudflare, so the token decides which hostnames a cluster answers for. Give a second cluster the same token and it becomes another connector on the same tunnel — Cloudflare will then load-balance those hostnames across both clusters. Create a separate tunnel, with its own hostname, for each cluster you deploy to.
:::

## Quick start — three commands

```bash
./uis network init cloudflare     # 1. interactive wizard, paste the tunnel token
./uis network up cloudflare       # 2. push token to cluster, deploy cloudflared
./uis network verify cloudflare   # 3. confirm DNS + port 7844 + e2e probe
```

The sections below walk through what each command does and what output to expect.

### 1. Create the tunnel in the Cloudflare dashboard

Before running any UIS command, create the tunnel in Cloudflare. UIS doesn't talk to the Cloudflare API — it deploys the in-cluster connector that points at a tunnel you created in the dashboard.

1. Go to [Zero Trust dashboard → Networks → Tunnels](https://one.dash.cloudflare.com).
2. **Create a tunnel** → Cloudflared connector type → pick a name.
3. Skip the install instructions for Linux/macOS/Windows — UIS deploys the connector for you. **Copy the tunnel token** (the long string starting with `ey...`) from the install command shown on the page.
4. Add a **Public Hostname** routing rule:
   - Subdomain: `*` (or a specific name like `whoami`)
   - Domain: pick your domain (e.g. `skryter.no`)
   - Service: `HTTP → traefik.kube-system.svc.cluster.local:80`

Routing happens server-side at Cloudflare; the cluster only needs to know the token.

### 2. Run the init wizard

```bash
./uis network init cloudflare
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
./uis network up cloudflare
```

Two stages:

1. **`uis secrets generate` + `uis secrets apply`** — pushes the token from the local env file into the `urbalurba-secrets` Secret in the cluster. This is the same pipeline every other UIS secret uses.
2. **`ansible-playbook 820-deploy-network-cloudflare-tunnel.yml`** — applies the static `820-cloudflare-tunnel-base.yaml` manifest (a Deployment with one `cloudflared` replica) and waits for the pod to reach `Running`. The playbook also runs a final HTTPS probe through your domain if `BASE_DOMAIN_CLOUDFLARE` is set.

The pod registers with Cloudflare's edge within ~15 seconds. After that, any service with a Traefik IngressRoute matching `*.your-domain.com` is reachable on the public internet.

### 4. Verify

```bash
./uis network verify cloudflare
```

Runs five checks:

| # | Check | What it confirms |
|---|---|---|
| 1 | Secrets | `CLOUDFLARE_TUNNEL_TOKEN` is set in the cluster Secret and not a placeholder |
| 2 | Network | DNS resolves `region1.v2.argotunnel.com` and TCP/7844 is reachable (corporate firewalls sometimes block it) |
| 3 | Pods | All `cloudflared` pods are in `Running` phase |
| 4 | Logs | Recent pod logs contain `Registered tunnel connection` |
| 5 | End-to-end | HTTPS probe to `https://<BASE_DOMAIN_CLOUDFLARE>` returns 200/301/302/404 (skipped if the domain wasn't set in init) |

A `PASS` on every line means traffic is flowing through the tunnel.

### 5. Day-2 commands

```
./uis network status cloudflare   # config + pod state, plus log tail if pods aren't Running
./uis network list                # one-line state across all providers
./uis network down cloudflare     # remove the in-cluster Deployment
```

`uis network down cloudflare` only deletes the in-cluster `cloudflared` Deployment. The tunnel itself in the Cloudflare dashboard is preserved, so re-running `uis network up cloudflare` reconnects the same tunnel. To retire the tunnel completely, delete it from Zero Trust → Networks → Tunnels.

The `.uis.secrets/service-keys/cloudflare.env` file is preserved across `down` / `up` cycles so you don't have to re-paste the token. Delete it manually if you want a full reset.

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

The token from the dashboard wasn't picked up by the secrets pipeline. Verify both files have the real token (not `your-cloudflare-tunnel-token-here`):

```
./uis network status cloudflare     # confirms the local env file
./uis secrets status                # confirms the master template
```

If the master template still has the placeholder, re-run `./uis network init cloudflare`. The wizard patches both files atomically.

**Pods come up but the domain returns 502**

The cloudflared pods are connected to Cloudflare's edge but the routing rule in the dashboard points at a service that isn't ready. Check the Traefik route:

```
kubectl get ingressroute -A
kubectl -n kube-system get svc traefik
```

The dashboard rule should send traffic to `traefik.kube-system.svc.cluster.local:80` (or `:443` if you're terminating TLS in the cluster).

**`./uis network verify cloudflare` says port 7844 is blocked**

Corporate firewalls sometimes block outbound 7844. The tunnel won't establish. Try from a different network, or contact your network team — Cloudflare publishes the [outbound port list](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/configure-tunnels/cloudflared-parameters/network/).

## Cost

The cloudflared connector is free. Cloudflare's free plan covers tunnels, WAF basics, and unmetered DDoS protection. You pay for the domain registration ($10–15/year for most TLDs) and only need a paid Cloudflare plan if you want advanced WAF rules, image optimization, or higher request limits.

## Learn more

- [Cloudflare tunnel official docs](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) — concepts, dashboard reference, advanced routing
- [Cloudflare setup (deep dive)](./cloudflare-setup.md) — historical UIS-specific setup notes covering DNS automation and multi-environment patterns
- [Traefik ingress rules](../contributors/rules/ingress-traefik.md) — how `HostRegexp` routes traffic across localhost, Tailscale, and Cloudflare
