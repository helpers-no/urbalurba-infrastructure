# INVESTIGATE: Cloudflare Tunnel UIS Integration

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: Make Cloudflare tunnel work through the UIS CLI with a similar operator experience as Tailscale, while respecting the architectural differences between the two.

**Last Updated**: 2026-02-24

**Priority**: Medium — Cloudflare is the production networking solution (custom domains, wildcard routing, CDN). Tailscale is for developer testing.

**Parent**: [STATUS-service-migration.md](STATUS-service-migration.md) — Phase 3 and Phase 5

**Requires**: Cloudflare account with a domain already added (e.g., `urbalurba.no`). May not work from corporate networks that block Cloudflare tunnel traffic.

---

## Context: Tailscale vs Cloudflare

Both provide tunnel access to the local cluster, but they serve different purposes and work differently.

| Aspect | Tailscale | Cloudflare |
|--------|-----------|------------|
| **Purpose** | Developer testing | Production / staging |
| **Domain** | Auto-assigned `*.ts.net` | User's custom domain (e.g., `urbalurba.no`) |
| **Wildcard routing** | No — each service needs individual ingress | Yes — `*.urbalurba.no` routes everything through one tunnel |
| **Architecture** | Tailscale operator + per-service proxy pods | Single `cloudflared` pod routes all traffic to Traefik |
| **Service exposure** | Per-service (`uis tailscale expose whoami`) | Automatic — all services with IngressRoutes are accessible |
| **Auth setup** | API tokens + OAuth client (automated) | Browser-based interactive login (requires human) |
| **TLS certs** | Let's Encrypt via Tailscale | Cloudflare edge (automatic, no rate limits) |
| **DNS management** | Automatic via MagicDNS | Automatic CNAME to tunnel |
| **CDN/DDoS** | No | Yes |
| **Requires parameter** | Service name for expose/unexpose | Domain name for initial setup |

### Key architectural difference

**Tailscale** creates a separate pod for each exposed service. You explicitly choose which services to expose.

**Cloudflare** creates one tunnel pod that routes ALL traffic to Traefik. Any service with a Traefik IngressRoute matching the domain is automatically accessible. There's no per-service expose/unexpose — the tunnel is either up (all services accessible) or down.

---

## Current State

### What exists

| File | Purpose | Status |
|------|---------|--------|
| `networking/cloudflare/820-cloudflare-tunnel-setup.sh` | Interactive setup (browser auth, create tunnel, configure DNS) | Untested in UIS |
| `networking/cloudflare/821-cloudflare-tunnel-deploy.sh` | Deploy tunnel pod to cluster | Untested in UIS |
| `networking/cloudflare/822-cloudflare-tunnel-delete.sh` | Complete tunnel cleanup | Untested in UIS, known DNS deletion bug |
| `ansible/playbooks/820-setup-network-cloudflare-tunnel.yml` | Ansible: create tunnel + DNS | Untested in UIS |
| `ansible/playbooks/821-deploy-network-cloudflare-tunnel.yml` | Ansible: deploy tunnel pod | Untested in UIS |
| `manifests/820-cloudflare-tunnel-base.yaml.j2` | K8s manifest template (Deployment + ConfigMap) | Routes `domain` + `*.domain` to Traefik |
| `provision-host/uis/services/network/service-cloudflare-tunnel.sh` | UIS service metadata | Wrong namespace in check command, no remove playbook |
| `website/docs/networking/cloudflare-setup.md` | User docs | References shell scripts, not UIS CLI |

### Known bugs

1. **Service check uses wrong namespace**: `service-cloudflare-tunnel.sh` checks `network` namespace but deployment is in `default`
2. **DNS route deletion broken**: `822-cloudflare-tunnel-delete.sh` reports success but DNS records remain in Cloudflare — requires manual deletion
3. **No remove playbook**: `SCRIPT_REMOVE_PLAYBOOK=""` in service script
4. **Deploy playbook mismatch**: Service script points to `820-setup-network-cloudflare-tunnel.yml` (interactive setup) instead of `821-deploy-network-cloudflare-tunnel.yml` (deploy to cluster)

---

## Design Decision: Token-Based Approach

### Problem: Interactive setup doesn't fit the UIS secrets pattern

The existing Cloudflare scripts use an interactive approach: `cloudflared login` opens a browser, generates a certificate, then `cloudflared tunnel create` generates tunnel credentials (JSON file). These generated files are stored outside the UIS secrets system.

This doesn't match how the rest of UIS works. Tailscale and all other services follow the pattern:
1. User configures values in `.uis.secrets/config/00-common-values.env`
2. `./uis secrets generate` creates K8s secrets
3. `./uis deploy <service>` reads from K8s secrets

### Solution: Use Cloudflare's token-based tunnel

Modern Cloudflare tunnels support a **token-based approach** ([docs](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/deployment-guides/kubernetes/)). The user creates the tunnel in the Cloudflare Zero Trust dashboard and gets a single token. The deployment is simply:

```yaml
command: ["cloudflared", "tunnel", "--metrics", "0.0.0.0:2000", "run", "--token", "$(CLOUDFLARE_TUNNEL_TOKEN)"]
```

This makes the flow identical to Tailscale:
1. User does manual steps in Cloudflare dashboard (create account, add domain, create tunnel, configure DNS)
2. User puts `CLOUDFLARE_TUNNEL_TOKEN` into `.uis.secrets/config/00-common-values.env`
3. `./uis secrets generate` creates the K8s secrets
4. `./uis deploy cloudflare-tunnel` deploys a pod running `cloudflared tunnel run --token`

**Benefits:**
- Follows the same secrets pattern as every other UIS service
- No `cloudflared` CLI needed in the container (only the Docker image for the tunnel pod)
- No interactive browser auth from inside the container
- No generated credential files to manage
- Simpler deployment manifest
- Simpler remove playbook (just delete K8s resources)

### Verified: Token-based approach works with wildcard routing

Confirmed from Cloudflare documentation and community guides (Feb 2026):

**Remotely-managed tunnels** (token-based) support all routing configuration from the dashboard. The `cloudflared` pod only needs the token — all ingress rules, public hostnames, and wildcard routes are pushed from Cloudflare's control plane automatically. No local config file or ConfigMap needed in the pod.

**Wildcard routing setup in dashboard:**
1. Zero Trust → Networks → Connectors → Create a tunnel → Cloudflared
2. Name the tunnel, copy the token (`eyJ...`)
3. In the tunnel's "Hostname routes" tab → "Published application routes", add:
   - `*.urbalurba.no` → service `http://traefik.kube-system.svc.cluster.local:80`
   - `urbalurba.no` → service `http://traefik.kube-system.svc.cluster.local:80`

**DNS records**: When adding published application routes, Cloudflare automatically creates DNS records of type "Tunnel" pointing to the tunnel name. However, if DNS records already exist (e.g., from a previously deleted tunnel), you must delete the old records first — otherwise you'll get: *"Error: An A, AAAA, or CNAME record with that host already exists."*

**Root domain route order matters**: Add the wildcard route (`*`) first. If the root domain CNAME already exists from a previous tunnel, delete it from DNS Records before adding the root domain route.

**Verified Feb 2026**: The Cloudflare Zero Trust UI has been reorganized. Tunnels are now under **Networks → Connectors** (not "Networks → Tunnels"). The tunnel configuration page uses tabs: Overview, CIDR routes, Hostname routes.

**Official K8s deployment pattern** (from [Cloudflare's K8s guide](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/deployment-guides/kubernetes/)):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudflared-deployment
spec:
  replicas: 2  # HA - replicas are for failover, not load balancing
  selector:
    matchLabels:
      pod: cloudflared
  template:
    metadata:
      labels:
        pod: cloudflared
    spec:
      containers:
        - image: cloudflare/cloudflared:latest
          name: cloudflared
          env:
            - name: TUNNEL_TOKEN
              valueFrom:
                secretKeyRef:
                  name: tunnel-token
                  key: token
          command:
            - cloudflared
            - tunnel
            - --no-autoupdate
            - --metrics
            - 0.0.0.0:2000
            - run
          livenessProbe:
            httpGet:
              path: /ready
              port: 2000
            failureThreshold: 1
            initialDelaySeconds: 10
            periodSeconds: 10
```

Key points from the official manifest:
- Token passed as `TUNNEL_TOKEN` env var from K8s Secret (not command-line arg — more secure)
- `--no-autoupdate` flag (container image handles updates)
- Liveness probe on `/ready` endpoint (port 2000) — the existing manifest lacks health checks
- 2 replicas recommended for HA (replicas are for failover only, not load balancing)

**References:**
- [Cloudflare Tunnel Kubernetes deployment guide](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/deployment-guides/kubernetes/) — official K8s manifest with token
- [Cloudflare Tunnel run parameters](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/cloudflared-parameters/run-parameters/) — `--token` and `TUNNEL_TOKEN` env var
- [Create a remote tunnel (dashboard)](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/create-remote-tunnel/) — dashboard setup flow
- [Wildcard tunnel setup guide](https://adampatterson.ca/development/setting-up-a-cloudflare-tunnel-with-wildcard-support/) — wildcard DNS CNAME requirement

### Keeping the interactive scripts

The existing interactive scripts represent significant work and are well-tested. They are moved to `legacy/` subdirectories — not deleted — in case we want the interactive approach back later.

| Current location | Move to |
|-----------------|---------|
| `networking/cloudflare/820-cloudflare-tunnel-setup.sh` | `networking/cloudflare/legacy/` |
| `networking/cloudflare/821-cloudflare-tunnel-deploy.sh` | `networking/cloudflare/legacy/` |
| `networking/cloudflare/822-cloudflare-tunnel-delete.sh` | `networking/cloudflare/legacy/` |
| `ansible/playbooks/820-setup-network-cloudflare-tunnel.yml` | `ansible/playbooks/legacy/` |
| `ansible/playbooks/821-deploy-network-cloudflare-tunnel.yml` | `ansible/playbooks/legacy/` |

A README.md in each `legacy/` folder will explain what these files are and why they were moved. The scripts can still be run manually from `./uis shell` if needed.

---

## Investigation Questions

### 1. Secrets system integration

The token-based approach needs these variables in the secrets system:

| Variable | Where | User provides |
|----------|-------|:---:|
| `BASE_DOMAIN_CLOUDFLARE` | `00-common-values.env` | Yes (already exists in template) |
| `CLOUDFLARE_TUNNEL_TOKEN` | `00-common-values.env` | Yes (from Cloudflare dashboard) |

Variables to clean up or update in templates:
- [x] `CLOUDFLARE_DNS_TOKEN` in `00-common-values.env.template` — still needed? Or replaced by tunnel token?
- [x] `CLOUDFLARE_TEST_TUNNELNAME`, `CLOUDFLARE_TEST_DOMAINNAME`, `CLOUDFLARE_TEST_SUBDOMAINS` in `00-master-secrets.yml.template` — remove (unused)
- [x] `CLOUDFLARE_PROD_*` variants in `00-master-secrets.yml.template` — remove (unused)
- [x] `cloudflare.env.template` in service-keys — update to match token-based approach
- [x] `CLOUDFLARE_API_TOKEN` naming inconsistency with `CLOUDFLARE_DNS_TOKEN` — resolve

### 2. Deployment manifest

The current `820-cloudflare-tunnel-base.yaml.j2` uses credential files mounted as volumes. For the token-based approach, we need a new/updated manifest:
- [x] Pod runs `cloudflared tunnel run --token <token>`
- [x] Token read from K8s secret (environment variable from `urbalurba-secrets`)
- [x] DNS routing configured in Cloudflare dashboard, not in the manifest's ConfigMap
- [x] Does the manifest still need the ingress rules ConfigMap, or does the dashboard config replace it?

### 3. UIS CLI design

| Command | Purpose | Interactive? |
|---------|---------|:---:|
| `./uis deploy cloudflare-tunnel` | Deploy tunnel pod (reads token from K8s secrets) | No |
| `./uis undeploy cloudflare-tunnel` | Remove K8s resources only — tunnel stays in Cloudflare for quick redeploy | No |
| `./uis cloudflare verify` | Check token, network connectivity (port 7844), tunnel pod status | No |
| `./uis cloudflare teardown` | Full cleanup: K8s resources + remind user to delete tunnel in Cloudflare dashboard | No |

**Compared to earlier interactive design:**
- Removed `./uis cloudflare setup <domain>` — setup happens in Cloudflare dashboard
- `teardown` no longer tries to delete Cloudflare-side resources via API (the DNS deletion bug is avoided entirely) — instead it reminds the user to clean up in the dashboard
- No browser auth from the container at all

### 4. Service script fixes

- [x] Fix `SCRIPT_CHECK_COMMAND` namespace (`default` not `network`)
- [x] Fix `SCRIPT_CHECK_COMMAND` label selector to match actual deployment labels
- [x] Set `SCRIPT_PLAYBOOK` to new token-based deploy playbook
- [x] Create remove playbook and set `SCRIPT_REMOVE_PLAYBOOK`

### 5. Two removal paths

**Light removal** (`./uis undeploy cloudflare-tunnel`):
- Remove K8s Deployment (`cloudflare-tunnel`)
- Remove K8s ConfigMap (if used)
- Keep tunnel alive in Cloudflare — just disconnect the connector
- Redeploy anytime with `./uis deploy cloudflare-tunnel`

**Full teardown** (`./uis cloudflare teardown`):
- Everything from light removal
- Print instructions: "Delete your tunnel in Cloudflare dashboard: Zero Trust → Networks → Tunnels"
- No API cleanup attempts (avoids the DNS deletion bug entirely)

### 6. Documentation updates

- [x] Rewrite `cloudflare-setup.md` for the token-based flow
- [x] Add step-by-step Cloudflare dashboard instructions (create account, add domain, create tunnel, get token)
- [x] Keep reference to legacy interactive scripts for advanced users
- [x] Add comparison table (already done in networking index.md)
- [x] Add port 7844 requirement and corporate network warning

### 7. Network connectivity pre-check

**Problem**: Cloudflare tunnels use **port 7844** (TCP and UDP) for the tunnel connection, not standard HTTPS port 443. Corporate networks often block non-standard ports, causing deploy to fail with confusing timeout errors.

**Reference**: [Cloudflare tunnel firewall docs](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-with-firewall/)

**How `cloudflared` connects**:
- Primary: outbound TCP/UDP on **port 7844** to Cloudflare's edge (required)
- Fallback: automatically tries available protocols (HTTP/2 over TCP, QUIC over UDP)
- Optional: port 443 for software update checks (non-critical)

**`./uis cloudflare verify` should include a network pre-check**:

```
Cloudflare Network Connectivity:
  DNS resolution (region1.v2.argotunnel.com)  ... OK
  TCP port 7844 (tunnel data channel)         ... BLOCKED ← will fail
  HTTPS to dash.cloudflare.com                ... OK

⚠️  Port 7844 is blocked on this network.
    Cloudflare tunnels require outbound TCP/UDP on port 7844.
    Try from a different network (home, mobile hotspot).
```

**Implementation**: Simple shell checks inside the verify command:
- `nslookup region1.v2.argotunnel.com` — DNS resolution
- `timeout 5 bash -c 'echo > /dev/tcp/region1.v2.argotunnel.com/7844'` — TCP port check
- `curl -s -o /dev/null -w '%{http_code}' https://dash.cloudflare.com` — HTTPS check

---

## Expected Deliverables

1. Fix `service-cloudflare-tunnel.sh` (namespace, label, playbook references)
2. Update secrets templates (`00-common-values.env.template`, `00-master-secrets.yml.template`) for token-based approach
3. Create or update deploy playbook for token-based deployment
4. Create remove playbook for light removal (`./uis undeploy`)
5. Add `./uis cloudflare` CLI commands to `uis-cli.sh` (verify, teardown)
6. Rewrite `cloudflare-setup.md` for token-based flow with dashboard instructions
7. Add port 7844 requirement and corporate network warning to docs
8. Add legacy script notes pointing to the new token-based approach
9. Test full cycle: configure secrets → deploy → verify → undeploy → redeploy → teardown
10. Tailscale vs Cloudflare comparison already added to networking index.md

---

## Related Files

| File | Role |
|------|------|
| `provision-host/uis/services/network/service-cloudflare-tunnel.sh` | Service metadata (needs fixes) |
| `provision-host/uis/manage/uis-cli.sh` | CLI entry point (add cloudflare commands) |
| `networking/cloudflare/820-cloudflare-tunnel-setup.sh` | Interactive setup script |
| `networking/cloudflare/821-cloudflare-tunnel-deploy.sh` | Deploy script |
| `networking/cloudflare/822-cloudflare-tunnel-delete.sh` | Delete script (DNS bug) |
| `ansible/playbooks/820-setup-network-cloudflare-tunnel.yml` | Setup playbook |
| `ansible/playbooks/821-deploy-network-cloudflare-tunnel.yml` | Deploy playbook |
| `manifests/820-cloudflare-tunnel-base.yaml.j2` | K8s manifest template |
| `website/docs/networking/cloudflare-setup.md` | User docs |
| `provision-host/uis/templates/uis.secrets/service-keys/cloudflare.env.template` | Secrets template (currently unused) |

## Reference: Tailscale Implementation (pattern to follow)

| Tailscale File | Cloudflare Equivalent |
|----------------|----------------------|
| `service-tailscale-tunnel.sh` | `service-cloudflare-tunnel.sh` (needs fixes) |
| `801-remove-network-tailscale-tunnel.yml` | Missing — needs creation |
| `802-deploy-network-tailscale-tunnel.yml` | `821-deploy-network-cloudflare-tunnel.yml` |
| `803-verify-tailscale.yml` | Missing — needs creation |
| `cmd_tailscale()` in `uis-cli.sh` | `cmd_cloudflare()` — needs creation |

## Verified: Cloudflare Dashboard Walkthrough (2026-02-24)

Completed full dashboard setup with user. Key findings:

1. **Tunnel created**: Name `urbalurba-no`, ID `3b2aa510-91cd-4f59-962b-6d553086b324`
2. **Token obtained**: Stored in `.uis.secrets/config/00-common-values.env` as `CLOUDFLARE_TUNNEL_TOKEN`
3. **Two routes configured**:
   - `*.urbalurba.no` → `http://traefik.kube-system.svc.cluster.local:80`
   - `urbalurba.no` → `http://traefik.kube-system.svc.cluster.local:80`
4. **DNS records auto-created** as "Tunnel" type (not raw CNAME) when adding published application routes
5. **Root domain route failed initially** because an old CNAME record existed from a previously deleted tunnel — had to delete the old DNS record first, then re-add the route
6. **UI navigation changed**: Tunnels are now under **Networks → Connectors** (not "Networks → Tunnels")
7. **Tunnel status**: Shows "Inactive" until a `cloudflared` pod connects with the token
8. **Service URL**: Must be `traefik.kube-system.svc.cluster.local:80` (Traefik runs in `kube-system` namespace in Rancher Desktop)
9. **Setup guide updated**: `docs/networking/cloudflare-setup.md` rewritten with token-based approach and exact dashboard steps

**Result**: Investigation complete. Implemented as [PLAN-012](../completed/PLAN-012-cloudflare-tunnel-token-deploy.md) — token-based deployment with K8s manifest, Ansible playbooks, CLI commands, secrets integration, and E2E testing. All 5 verify checks pass, HTTP 200 end-to-end confirmed.

---

## External References

- [Cloudflare Tunnel firewall requirements](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-with-firewall/) — port 7844 TCP/UDP, required hostnames and IPs
- [Cloudflare connectivity pre-checks](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/troubleshoot-tunnels/connectivity-prechecks/) — built-in diagnostic tools
- [Cloudflare Tunnel documentation](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/) — general tunnel docs
- [Adding a domain to Cloudflare](https://developers.cloudflare.com/fundamentals/setup/manage-domains/add-site/) — prerequisite for tunnel setup
