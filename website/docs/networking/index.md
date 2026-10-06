---
title: Networking
sidebar_label: Overview
sidebar_position: 1
---

# Networking

UIS targets **multiple networking providers** from a single command interface. Cloudflare tunnels expose services on a domain you own. Tailscale Funnel + Tailscale internal ingress give you tunnel-style or VPN-style access without a public domain. All of them speak the same `uis network ...` vocabulary, so swapping the path your services take to the internet is a CLI flag away.

## Which one should I use?

You probably want **one** of these — most users don't need both. Pick by what you're trying to do:

| If you want to… | Use | Why |
|---|---|---|
| Quickly show a service on your laptop to a colleague | **Tailscale Funnel** | No domain needed (get a free `<thing>.ts.net` URL), no Cloudflare account, works from any network including corporate Wi-Fi |
| Run a service for real (own DNS, WAF, DDoS protection, predictable URL) | **Cloudflare tunnel** | You already own the domain, Cloudflare handles certs and edge security, wildcard subdomain routing works |
| Both — different services on different paths | Both | They coexist. The same backend pod can answer on `whoami.localhost`, `whoami.<your-name>.ts.net`, and `whoami.your-domain.com` simultaneously |

The decision typically comes down to **three constraints**:

1. **Do you own a domain Cloudflare can host DNS for?** No → Tailscale is your option. Yes → either works.
2. **Does your network allow outbound TCP/7844?** Some corporate networks block it. Cloudflare needs it. Tailscale uses UDP/443 + DERP relay, which goes through almost anything.
3. **How many services do you want to expose?** Cloudflare gives you wildcard subdomain routing for free — one tunnel handles `*.your-domain.com`. Tailscale Funnel has no wildcard DNS, so you `uis network expose tailscale <service>` for each one you want public.

**On security:** both paths terminate TLS at the provider's edge and reach into the cluster over an outbound-only connection — no inbound ports, no public IP on your side. Cloudflare adds a free WAF and DDoS protection in front. Tailscale Funnel sits behind Tailscale's own infrastructure with no built-in WAF. Authentik forward-auth in front of Traefik still works for Cloudflare paths; **it does not work for Tailscale Funnel**, because the Tailscale operator's per-service proxy routes directly to the backend service and bypasses Traefik entirely. If you want auth on a Tailscale-exposed service, the service has to enforce it itself.



## See what you have

`uis network list` shows every provider UIS knows about and its current state:

```
$ uis network list
PROVIDER     STATUS
cloudflare   ✓ running                   (1/1 cloudflared pods up)
tailscale    ✓ running                   (1/1 operator pod up, 2 service(s) exposed)
```

The status column uses the same four-state vocabulary as `uis platform list`:

| State | Meaning | Typical hint |
|---|---|---|
| `✓ running` | Provider is deployed and at least one pod is in the `Running` phase | provider-specific (e.g. `1/1 cloudflared pods up`) |
| `· configured, not running` | `init` has been run (env file exists), no provider deployment in the cluster | `run './uis network up <provider>' to deploy` |
| `· not initialized` | UIS has no configuration for this provider yet | `run './uis network init <provider>' to set up` |
| `✗ unreachable` | Deployment exists but no pods are Running | `check 'kubectl -n default logs -l app=<provider>'` |

The list emits no probes against external services — it inspects the local secrets file and the in-cluster deployment only.

## Vocabulary

Every provider supports the same five verbs:

| Verb | What it does |
|---|---|
| `uis network init <provider>` | Interactive wizard that writes `.uis.secrets/service-keys/<provider>.env` and patches `secrets-config/00-common-values.env.template` so `uis secrets generate` picks up the value. |
| `uis network up <provider>` | Runs `uis secrets generate` + `uis secrets apply` (pushes credentials into the `urbalurba-secrets` k8s Secret), then deploys the in-cluster manifest for the provider. |
| `uis network status <provider>` | Shows config + pod state for the provider. `--summary` flag emits the tab-separated `<state>\t<hint>` line consumed by `uis network list`. |
| `uis network verify <provider>` | End-to-end checks: secrets, DNS, port reachability, pod logs, HTTPS probe through the tunnel. |
| `uis network down <provider>` | Removes the in-cluster deployment. The provider-side configuration (e.g. the tunnel in the Cloudflare dashboard) is preserved. |

The wizard never deploys anything. Init writes config; up deploys.

## Provider status

| Provider | CLI port | Deploy path | Notes |
|---|---|---|---|
| **Cloudflare** | ✅ `uis network ... cloudflare` | In-cluster `cloudflared` pods, token-based | Verified on rancher-desktop with `*.skryter.no`. See [Cloudflare tunnel](./cloudflare.md). |
| **Tailscale** | ✅ `uis network ... tailscale` | In-cluster Tailscale operator + per-service Funnel devices, OAuth-based | Verified end-to-end on rancher-desktop against `dog-pence.ts.net`. See [Tailscale Funnel](./tailscale.md) for the three-command novice path. |

## How traffic reaches your services

Cluster services are matched by Traefik `HostRegexp` ingress rules (e.g. `whoami\..+`). The same IngressRoute resolves three different paths to the same backend pod:

- `whoami.localhost` — direct on the developer laptop
- `whoami.<device>.ts.net` — through Tailscale Funnel
- `whoami.skryter.no` — through Cloudflare tunnel

You don't change the ingress to switch providers — you add or remove the network path. See [Traefik](../services/networking/traefik.md) for the ingress controller details and [Traefik ingress rules](../contributors/rules/ingress-traefik.md) for the `HostRegexp` pattern.

## Pages in this section

- **[Cloudflare tunnel](./cloudflare.md)** — three-command novice path for `cloudflared` in-cluster, token-based.
- **[Cloudflare advanced topics](./cloudflare-setup.md)** — CORS at the edge, reserved hostname prefixes, 403/bot diagnosis, caching, availability, DNS edge cases.
- **[Tailscale Funnel](./tailscale.md)** — three-command novice path for the Tailscale operator + per-service Funnel exposure.
- **[Tailscale setup (deep dive)](./tailscale-setup.md)** — dashboard walk-through, ACL JSON, OAuth scopes, MagicDNS.
- **[Tailscale network isolation](./tailscale-network-isolation.md)** — design proposal for host-network-isolation hardening (not implemented; design reference only).
