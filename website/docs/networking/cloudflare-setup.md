# Cloudflare Tunnel Setup Guide

**Purpose**: Professional internet access with custom domains
**Audience**: Users wanting production-ready setup with own domains
**Time Required**: 15-20 minutes
**Prerequisites**: Working cluster with Traefik ingress

## Quick Summary

Transform your local cluster from `http://service.localhost` to `https://service.yourcompany.com` with enterprise-grade security. Uses your Cloudflare-managed domain to provide global CDN, DDoS protection, and professional appearance.

## Prerequisites

Before starting, ensure you have:
- [ ] Kubernetes cluster running (Rancher Desktop or similar)
- [ ] Traefik ingress controller deployed
- [ ] Services accessible locally (e.g., `http://whoami.localhost`)
- [ ] A Cloudflare account ([sign up](https://dash.cloudflare.com/sign-up))
- [ ] A domain added to Cloudflare with nameservers pointing to Cloudflare

## How Cloudflare Tunnel Works

The Cloudflare tunnel creates a secure outbound connection from your cluster to Cloudflare's edge:

```
Internet User → Cloudflare Edge (CDN/WAF) → Tunnel → Traefik → Your Services
```

**Key Benefits:**
- No port forwarding or firewall configuration needed
- Automatic SSL/TLS certificates (no rate limits like Let's Encrypt)
- DDoS protection and global CDN
- Works behind NAT/firewalls
- Wildcard routing: `*.yourdomain.com` routes all subdomains through one tunnel

**How it differs from Tailscale:**
- Cloudflare exposes ALL services with Traefik IngressRoutes automatically (one tunnel pod)
- Tailscale exposes services individually (one pod per service)
- See [Networking Overview](index.md) for a full comparison

## Setup Overview

The token-based approach follows the same pattern as all other UIS services:

1. **Configure in Cloudflare dashboard** (one-time): Create tunnel, get token, configure routes
2. **Initialise UIS with the token**: `./uis network init cloudflare` (interactive wizard, writes the token + domain to `.uis.secrets/`)
3. **Deploy**: `./uis network up cloudflare`

No interactive browser auth from the container. No generated credential files.

---

## Step 1: Add Your Domain to Cloudflare

*Skip this if your domain is already in Cloudflare.*

1. Log in to [dash.cloudflare.com](https://dash.cloudflare.com)
2. Click **"Add a domain"**
3. Enter your domain (e.g., `urbalurba.no`)
4. Select the **Free** plan
5. Cloudflare will scan existing DNS records — review and confirm
6. Update your domain registrar's nameservers to the Cloudflare nameservers shown (e.g., `sandy.ns.cloudflare.com` and `terry.ns.cloudflare.com`)
7. Wait for nameserver propagation (usually 5-30 minutes, can take up to 24 hours)

**Verify**: Your domain should show "Active" status in the Cloudflare dashboard.

## Step 2: Create a Tunnel in Cloudflare Zero Trust

1. Go to [Cloudflare Zero Trust](https://one.dash.cloudflare.com)
2. In the left sidebar, click **Networks → Connectors**
3. Under "Cloudflare Tunnels", click **"Create a tunnel"**
4. Select **Cloudflared** as the connector type
5. Give your tunnel a name (e.g., `urbalurba-no`) and click **Save tunnel**

### Copy the tunnel token

After creating the tunnel, Cloudflare shows installation instructions. Look for the command:

```
cloudflared tunnel run --token eyJhIjoiOT...
```

**Copy the entire token** (the long `eyJ...` string). This is the only secret you need.

Save it somewhere safe — you'll put it in the UIS secrets config in Step 4.

## Step 3: Configure Public Hostname Routes

After saving the tunnel, you'll be on the tunnel configuration page. Click the **Hostname routes** tab.

> **Console naming (current UI).** The tunnels page is titled **"Tunnels & Mesh"**, and *Create a tunnel* asks for a **Tunnel type**: pick **`cloudflared`**. **Mesh** is a different product for bidirectional connectivity and will not give you a public hostname. The route form labels the first field **Hostname** (hint `e.g., www, blog, api`) rather than "Subdomain", and shows a **Full hostname** preview — read that preview back before saving, since a hostname that silently didn't register leaves you routing the apex instead.

> **Important: the Beta "Hostname routes" tab has TWO sections.** Scroll down to **"Published application routes"** (the lower section). The upper section, titled "Your hostname routes", is for **Cloudflare One / WARP-client private access** — it has a simpler form (just hostname + description) and is **not** what UIS needs. Adding a route in the upper section will trigger a "Cloudflare One Client device profile" popup and will *not* create the public DNS record you need. If you see a form without Service Type / URL fields, you're in the wrong section.

### Add wildcard route (all subdomains)

In the **Published application routes** section, click **"Add a published application route"**:

| Field | Value |
|-------|-------|
| **Subdomain** | `*` |
| **Domain** | Select your domain (e.g., `urbalurba.no`) |
| **Path** | *(leave empty)* |
| **Type** | HTTP |
| **URL** | `traefik.kube-system.svc.cluster.local:80` |

Click **Save**.

> **If a "Cloudflare One Client device profile" popup appears** asking about Split Tunnels and the `100.64.0.0/10` CGNAT range — click **Confirm**. This is a generic Zero Trust warning that fires whenever you point a route at a `.cluster.local` origin. It does **not** apply to UIS's public-tunnel use case (no WARP client involved). Clicking Cancel will abort the save.
>
> ⚠️ **This applies when you EDIT an existing route, not only when you create one — and there it is far more dangerous.** Cancelling leaves the route holding its previous origin, with no error and a form that looks like it saved. On 2026-09-18 that cost an operator a 502 on every request while the Cloudflare dashboard showed the tunnel as Healthy and `uis network status` showed the pod as Running. **Always re-open the route and read the Service URL back after saving.**

### Add root domain route

Click **"Add a published application route"** again:

| Field | Value |
|-------|-------|
| **Subdomain** | *(leave empty)* |
| **Domain** | Select your domain (e.g., `urbalurba.no`) |
| **Path** | *(leave empty)* |
| **Type** | HTTP |
| **URL** | `traefik.kube-system.svc.cluster.local:80` |

Click **Save**.

### Verify both halves: published route AND DNS record

A Cloudflare tunnel route needs **two** things to actually serve traffic, and they live in different places:

1. A **Published Application Route** (you just added these) — tells the tunnel which origin URL to forward each hostname's traffic to.
2. A **DNS record** under `DNS → Records` — tells Cloudflare's edge which tunnel to send traffic for that hostname to.

When you save a published route, Cloudflare *normally* auto-creates the matching DNS record (displayed as `Type: Tunnel`). **This auto-create is not 100% reliable** — it sometimes silently skips for wildcards, apex/root domains, or when conflicting records already exist.

**After saving each route, verify** by going to `dash.cloudflare.com → <your-domain> → DNS → Records`. You should see two rows added by the tunnel:

| Type | Name | Content | Proxy status |
|------|------|---------|--------------|
| Tunnel | `*` | `<your-tunnel-name>` | Proxied (orange cloud) |
| Tunnel | `<your-domain>` (or `@`) | `<your-tunnel-name>` | Proxied (orange cloud) |

**If a row is missing**, add it manually: click **Add record**, set Type to `CNAME`, Name to `*` (or `@` for root), Target to `<your-tunnel-uuid>.cfargotunnel.com` (find the UUID on the tunnel's Overview tab), and **Proxy status: Proxied (orange cloud)**. Save.

> **The "record already exists" error** (*"An A, AAAA, or CNAME record with that host already exists"*) happens in two cases:
> - There's a stale DNS record from a previous tunnel or another service (e.g., Squarespace A records, an old CNAME). **Fix**: in DNS → Records, find and delete the conflicting row, then re-save the route.
> - You manually added a DNS record before saving the matching Published Application Route, and the route's auto-create is now trying to create a duplicate. **Fix**: delete your manual DNS record, then save the route — Cloudflare will auto-create the correct one.

### Verify your routes

Your tunnel should now show two published application routes:

| # | Route | Path | Service |
|---|-------|------|---------|
| 1 | `*.urbalurba.no` | `*` | `http://traefik.kube-system.svc.cluster.local:80` |
| 2 | `urbalurba.no` | `*` | `http://traefik.kube-system.svc.cluster.local:80` |

…and matching `Type: Tunnel` rows in DNS → Records.

> **"No connection detected yet" / Continue button disabled** during tunnel creation — Cloudflare's tunnel wizard shows install instructions for `cloudflared` and a Connection Status panel that polls for the connector. The Continue button stays disabled until the connector connects. In UIS the connector is the K8s pod that gets deployed in Step 5 below — not running yet. **You can configure hostname routes on the tunnel's detail page without finishing the wizard**: click "Cancel" on the install screen (the tunnel itself is already saved), navigate back to `Networks → Tunnels → <your tunnel>`, and proceed with Step 3 from there. After Step 5, the dashboard will show the connector as Healthy.

## Step 4: Configure UIS with the Tunnel Token

Run the interactive init wizard:

```bash
./uis network init cloudflare
```

The wizard prompts for two values:

- **`CLOUDFLARE_TUNNEL_TOKEN`** — paste the long `eyJ...` string you copied in Step 2.
- **`BASE_DOMAIN_CLOUDFLARE`** — your domain, e.g. `urbalurba.no` (used by `uis network verify cloudflare`'s end-to-end probe; press Enter to skip if you want to set it later).

The wizard writes two files:

- `.uis.secrets/service-keys/cloudflare.env` — the canonical source-of-truth (owner-only `chmod 600`)
- `.uis.secrets/secrets-config/00-common-values.env.template` — the matching template lines get patched in place

**The wizard requires an interactive terminal** — it intentionally refuses non-TTY stdin to prevent token leaks through shell history or piped scripts. If you need to drive it non-interactively (e.g. CI), edit the files directly: put `CLOUDFLARE_TUNNEL_TOKEN=...` and `BASE_DOMAIN_CLOUDFLARE=...` into `.uis.secrets/service-keys/cloudflare.env` with mode `0600`.

> **Re-running the wizard**: if `cloudflare.env` already exists, the wizard shows a three-option menu — Skip / Re-prompt / Show. Pick Show to inspect the current values, Re-prompt to rotate the token.

## Step 5: Deploy the Tunnel

```bash
./uis network up cloudflare
```

This is a two-stage command:

1. **Stage 1/2** — pushes the token into the `urbalurba-secrets` Kubernetes Secret (runs `uis secrets generate` + `uis secrets apply` under the hood).
2. **Stage 2/2** — applies the manifest and waits for the cloudflared pod to register with Cloudflare's edge (`ansible-playbook 820-deploy-network-cloudflare-tunnel.yml`).

The default manifest deploys **1 cloudflared pod**. On single-node clusters (Rancher Desktop), more replicas wouldn't add fault tolerance (all pods would land on the same node anyway). A `--replicas` flag for multi-node clusters is on the roadmap.

When the command finishes you'll see `✓ Cloudflare tunnel is up`. The tunnel status in the Cloudflare dashboard will change from **Inactive** to **Healthy** within a few seconds.

## Step 6: Verify

```bash
# Run all verification checks
./uis network verify cloudflare
```

This runs 5 checks:
1. **Secrets** — `CLOUDFLARE_TUNNEL_TOKEN` is configured and not a placeholder
2. **Network** — DNS resolves and port 7844 is reachable
3. **Pods** — the cloudflared pod is running
4. **Logs** — Tunnel connection registered with Cloudflare edge
5. **End-to-end** — HTTP request through the tunnel returns a response

Quick state check:

```bash
./uis network list                 # provider table + pod count
./uis network status cloudflare    # detail panel (token char count, domain, pods)
```

You can also test manually:

```bash
# whoami's IngressRoute uses HostRegexp(whoami-public.*) — note the "-public" suffix
curl https://whoami-public.urbalurba.no

# Root domain hits Traefik's catch-all (typically the nginx landing page)
curl https://urbalurba.no
```

The tunnel status in the Cloudflare dashboard should change from **Inactive** to **Healthy**.

> **Common mistake**: the whoami service's IngressRoute matches `HostRegexp(whoami-public.*)`, **not** `whoami.*`. A curl to `https://whoami.urbalurba.no` will return 404 because no IngressRoute matches that exact hostname. Same applies to other services — check the actual IngressRoute pattern (`kubectl get ingressroutes -A`) before forming URLs.
>
> **And a 404 here is a PASS, not a failure.** It means the request crossed the whole chain and Traefik had nothing matching that hostname — the tunnel works. Traefik's 404 is 19 bytes of `text/plain` reading `404 page not found`; Cloudflare's errors are HTML. What is *not* a pass: **502** (connector registered, origin unreachable — check the Service URL's namespace) and **530** (Cloudflare cannot reach the tunnel at all).

---

## Managing the Tunnel

### Take down the tunnel (keep config for redeployment)

```bash
./uis network down cloudflare
```

This removes the Kubernetes resources (deployment + pods) but **preserves** `.uis.secrets/service-keys/cloudflare.env` so you can redeploy without re-running the init wizard. Redeploy with `./uis network up cloudflare` — same token, same domain, ready in ~20 seconds. The Cloudflare-side tunnel and Published Application Routes are also preserved (they're dashboard state, not affected by the local down).

### Full teardown (forget the token)

```bash
./uis network down cloudflare
rm .uis.secrets/service-keys/cloudflare.env
```

Then optionally, in the Cloudflare dashboard: `Zero Trust → Networks → Tunnels → <your tunnel> → … → Delete`. The dashboard cleanup is independent of the local state and is only needed if you're retiring the tunnel altogether.

---

## Troubleshooting

### Common Issues

| Problem | Cause | Solution |
|---------|-------|----------|
| Tunnel stays "Inactive" | Pod not running or can't connect | Check pod logs: `kubectl logs -l app=cloudflared --tail=50` |
| 502 Bad Gateway | Traefik not running or wrong service URL | Verify Traefik: `kubectl get pods -l app.kubernetes.io/name=traefik` |
| Connection timeout | Port 7844 blocked by network | See "Port 7844 Blocked" below |
| DNS record conflict | Old CNAME from deleted tunnel | Delete old DNS record, re-add route |
| "Worker is Running!" on root domain | Cloudflare Worker intercepting traffic | Check Workers & Pages, remove Worker routes |
| `NXDOMAIN` / "Could not resolve host" for subdomain | Wildcard DNS record missing (auto-create failed) | See "DNS auto-create didn't fire" below |
| `HTTP/2 404` from `server: cloudflare` despite DNS resolving | Published Application Route missing, or stale Private hostname route | See "404 from Cloudflare edge" below |
| Continue button greyed out during tunnel creation | Wizard expects connector to connect first | Cancel the wizard and configure routes from the tunnel detail page — see Step 3 |
| "Cloudflare One Client device profile" popup on route save | You're in the wrong section (Private hostnames) | Use "Published application routes" section, not "Your hostname routes" — see Step 3 |
| Whoami curl returns 404 from traefik (not Cloudflare) | Wrong hostname — IngressRoute uses `whoami-public.*`, not `whoami.*` | Use `https://whoami-public.<your-domain>` |

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

**Fix**: go to `Networks → Tunnels → <your-tunnel> → Hostname routes → Published application routes` and verify there's a row covering this hostname. If missing, add it (Step 3). If you previously added a route in the upper "Your hostname routes" section by mistake — that's a Private route and doesn't serve public traffic — delete it and re-add in the Published Application Routes section.

### Stale DNS records from prior domain owners

If your domain was previously used elsewhere (Squarespace, Wix, one.com, GitHub Pages, etc.), the DNS zone may contain leftover A/CNAME records that proxy traffic to the old origin. These show up as:

- `A` rows at the apex pointing to non-Cloudflare IPs (e.g., Squarespace `198.185.x.x` or `198.49.x.x`)
- `CNAME` rows for subdomains pointing to provider hostnames (e.g., `*.squarespace.com`, `ghs.google.com` for old Google Sites)
- `NS` rows at the apex pointing to a previous registrar's nameservers (cosmetic leftover; the registrar-level NS is what actually matters)

To use the domain with Cloudflare Tunnel, delete the old A/CNAME records that conflict with the tunnel routes. Leave MX records (email), TXT records (verification/SPF), and the registrar-level NS configuration alone.

### Port 7844 Blocked (Corporate Networks)

Cloudflare tunnels use **port 7844** (TCP and UDP) for the tunnel connection, not standard HTTPS port 443. Corporate and school networks often block this port.

**Symptoms:**
- Tunnel pod starts but stays in "connecting" state
- Logs show connection timeouts to Cloudflare edge
- `./uis network verify cloudflare` reports port 7844 as blocked

**Solutions:**
1. **Switch networks**: Use home WiFi or mobile hotspot
2. **Use VPN**: Route traffic through a VPN that allows port 7844
3. **Ask IT**: Request outbound access to port 7844 TCP/UDP

**Reference**: [Cloudflare tunnel firewall requirements](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-with-firewall/)

### Checking Tunnel Status

```bash
# View tunnel pod status
kubectl get pods -l app=cloudflared

# Check tunnel logs
kubectl logs -l app=cloudflared --tail=50

# In Cloudflare dashboard: Zero Trust → Networks → Connectors
# Your tunnel should show "Healthy" status
```

---

## Architecture

### Traffic Flow
```
User Request → Cloudflare Edge (CDN/WAF/TLS) → Tunnel Pod → Traefik → Service
```

### Components
- **Cloudflare Edge**: Global CDN, DDoS protection, TLS termination
- **Tunnel Connector**: 1 `cloudflared` pod in your cluster (single replica by default; multi-replica HA on multi-node clusters is on the roadmap)
- **Traefik**: Ingress controller routing to services via IngressRoutes
- **Services**: Your applications with HostRegexp IngressRoute patterns

### DNS Configuration
When you add published application routes, Cloudflare automatically creates:
- **Root domain**: `urbalurba.no` → Tunnel type DNS record
- **Wildcard**: `*.urbalurba.no` → Tunnel type DNS record
- **Proxied**: Orange cloud enabled for CDN and security

### How Wildcard Routing Works

With the wildcard route (`*.urbalurba.no`), ALL subdomains automatically reach your cluster:

```
whoami-public.urbalurba.no  → Cloudflare → cloudflared pod → Traefik → whoami service
openwebui.urbalurba.no       → Cloudflare → cloudflared pod → Traefik → openwebui service
grafana.urbalurba.no         → Cloudflare → cloudflared pod → Traefik → grafana service
```

Traefik routes to the correct service using its HostRegexp IngressRoute rules. Each service deployed via UIS defines its own HostRegexp pattern — `whoami` uses `HostRegexp(whoami-public.*)`, others use their own conventions. **The IngressRoute pattern is what determines the URL**, not the service name alone. Inspect with:

```bash
kubectl get ingressroutes -A
kubectl get ingressroute <name> -n <namespace> -o yaml
```

A subdomain that doesn't match any specific IngressRoute falls through to Traefik's catch-all (typically `nginx-root-catch-all` serving the default nginx landing page), so an unconfigured subdomain still returns 200 — just from the catch-all, not the intended service. If you expect a specific service and see the nginx page instead, check the IngressRoute's HostRegexp pattern against your URL.

---

## Legacy: Interactive Setup Scripts

Previous versions used interactive shell scripts that required `cloudflared login` (browser auth) inside the container. These scripts have been moved to `legacy/` directories for reference:

| Script | Location |
|--------|----------|
| `820-cloudflare-tunnel-setup.sh` | `networking/cloudflare/legacy/` |
| `821-cloudflare-tunnel-deploy.sh` | `networking/cloudflare/legacy/` |
| `822-cloudflare-tunnel-delete.sh` | `networking/cloudflare/legacy/` |

The token-based approach is simpler and follows the same secrets pattern as all other UIS services.

## Additional Resources

- **Cloudflare Tunnel docs**: [Cloudflare Tunnel documentation](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/)
- **K8s deployment guide**: [Cloudflare Tunnel Kubernetes deployment](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/deployment-guides/kubernetes/)
- **Firewall requirements**: [Tunnel with firewall](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-with-firewall/)
- **Domain setup**: [Adding a domain to Cloudflare](https://developers.cloudflare.com/fundamentals/setup/manage-domains/add-site/)
- **Networking overview**: [Tailscale vs Cloudflare comparison](index.md)
