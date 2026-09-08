---
status: backlog
created: 2026-05-12
updated: 2026-05-13
related:
  - INVESTIGATE-network-cloudflare-in-cluster-restructure.md
  - PLAN-network-cloudflare-port-and-docs-lift-up.md
  - INVESTIGATE-network-tailscale-cross-cluster-backbone.md
  - completed/INVESTIGATE-tailscale-variable-rename.md
  - completed/PLAN-009-tailscale-service-fix.md
  - completed/PLAN-011-tailscale-cli-expose-commands.md
  - completed/INVESTIGATE-tailscale-api-device-cleanup.md
  - completed/INVESTIGATE-tailscale-cluster-tunnel-timeout.md
---

# INVESTIGATE: Tailscale architecture cleanup

**Status:** Completed

The Cloudflare CLI port (`uis network ... cloudflare`, PRs #169–#172) is shipped and verified end-to-end on rancher-desktop against `*.skryter.no`. This investigation prepares the equivalent cleanup for Tailscale.

Tailscale is **harder than Cloudflare** to port, for three reasons:

1. **Multiple deploy modes in the codebase.** Cloudflare has a single in-cluster `cloudflared` pod that the tunnel API routes everything through. Tailscale has (a) a public Funnel cluster ingress, (b) tailnet-only internal ingress, and (c) operator-only with per-service `expose`. All three are present in the codebase today; the cleanup deletes (b) per Decision 15, makes (a) opt-in per Decision 9, and treats (c) — per-service Funnel via `expose` — as canonical per Decision 8.
2. **Per-service exposure is a first-class operation.** `uis tailscale expose <service>` creates a tailnet device for one named service; `unexpose` removes it. Cloudflare has no equivalent — every service routed by Traefik's IngressRoute is reachable through the single tunnel. The Tailscale CLI cannot just be renamed; the per-service surface needs to fit somewhere in the new vocabulary.
3. **Architectural debt.** Two playbooks install the same Helm release with the same name; a third playbook deletes a resource that doesn't match what the second creates; one playbook is orphaned; six secret variables overlap, two of which are unused.

This document inventories the current state, locks in the decisions evidence already supports, and lists the open questions that PLAN time needs to answer.

---

## User-facing positioning (the "when to pick what" framing)

Cloudflare and Tailscale solve different problems. This investigation's user-facing decisions (wizard text, the `networking/tailscale.md` guide we'll eventually write, the CLI shape) flow from this:

| Dimension | Cloudflare | Tailscale |
|---|---|---|
| **Use case** | Production: customer-facing apps, branded URLs | Developer: "share my local cluster with someone" |
| **Firewall / WAF** | Built-in — DDoS protection, rules engine, bot management | None. You handle security at Traefik or above. |
| **DNS hosting** | Required — Cloudflare is the DNS provider for the domain you own | Not yours — uses Tailscale's `.ts.net` namespace |
| **Network reachability** | Outbound port `7844` (TCP/UDP). Sometimes blocked on corporate / hotel networks. | Works on any network (UDP `41641` with TLS `443` fallback via DERP relays). No port-blocking surface. |
| **In-cluster path** | Cloudflared pod → **Traefik** → service. Authentik forward-auth + Traefik middleware apply. | Tailscale operator's per-service proxy pod → service **directly**. Traefik bypassed; **no Authentik forward-auth**, no Traefik middleware. |
| **You need** | A domain you own + a Cloudflare account | A Tailscale account + tailnet (free for personal use) |
| **Cost** | $10–15/year for the domain; free Cloudflare plan covers most projects | Free up to 3 users / 100 devices |
| **URL shape** | `whoami.your-domain.com` — wildcard subdomain DNS lets Traefik HostRegexp-route anything under the apex | `<service>-<owner>.<tailnet>.ts.net` — Tailscale registers named devices per exposure; no wildcard subdomain DNS |

**Headline framing for the docs:**

- **Cloudflare** is the production answer. You get a domain you own, a real firewall in front of your cluster, and routes you control via Cloudflare's dashboard. Traffic flows through Traefik in the cluster, so Authentik forward-auth and other Traefik middleware apply. The trade-off is the outbound `7844` requirement and the operational complexity of owning a domain + DNS.
- **Tailscale** is the developer answer. You're running something on rancher-desktop and want a colleague (or your phone, or a Slack bookmark) to reach it from outside your home network. Tailscale's tailnet works on any network with no firewall ceremony — but **you don't get WAF**, **you don't get Authentik forward-auth** (Tailscale bypasses Traefik entirely; see below), you don't get your own domain, and the URL shape is constrained to named devices under `.ts.net`.

### Why per-service Funnel devices are canonical (the demo-flow analysis)

Walking through the realistic developer scenario — "I want my colleague to click a Slack link and reach OpenWebUI running on my rancher-desktop" — clarifies the constraint:

A real demo has the frontend making API calls from the colleague's browser. OpenWebUI's React app fetches `/api/chat` and possibly direct calls to a separate backend like `https://postgrest.<host>`. Each of those calls needs a public, browser-reachable hostname.

| Demo type | Single cluster Funnel + path routing | Per-service Tailscale devices |
|---|---|---|
| Static page (HTML only) | ✓ works | ✓ works |
| Single relative API call (`fetch('/api/...')`) | ✗ Traefik gets `/api/...` on cluster hostname; no matching IngressRoute → 404 | ✓ works (same hostname as frontend) |
| SPA calling separate backend (postgrest, auth API) | ✗ no second public hostname available | ✓ each service gets its own `<svc>.<tailnet>.ts.net` |
| Frameworks (Vite, Next.js, Astro) | ✗ all hardcode `/` paths, fight path-prefix routing | ✓ works (each service serves from its own root) |

**Conclusion:** Tailscale Funnel has no wildcard subdomain DNS, so the cluster-Funnel + Traefik-HostRegexp shape that Cloudflare uses isn't available. The only model that survives contact with a real multi-service app is **one Funnel device per exposed service** — `openwebui-terje.dog-pence.ts.net` for the UI, `postgrest-terje.dog-pence.ts.net` for the API. This isn't a workaround; it's the only shape Tailscale's URL constraint supports. The legacy `uis tailscale expose <service>` was right; the cleanup ports it into the new namespace, not deletes it.

### Tailscale Funnel bypasses Traefik

This is the second load-bearing architectural fact users need to understand. The cluster path differs structurally from Cloudflare's:

**Cloudflare path (current):**
```
internet → Cloudflare edge → cloudflared pod → Traefik → IngressRoute → service
                                                  ↑
                              Authentik forward-auth middleware applies here
```

**Tailscale path (per-service `expose`):**
```
internet → Tailscale edge → tailnet → operator's per-service proxy pod → service (direct)
                                                                          ↑
                                                          Traefik is not in this path
```

The Tailscale operator, when it sees an `Ingress` with `ingressClassName: tailscale` and `tailscale.com/funnel: "true"`, creates a dedicated proxy pod that forwards directly to the backend Kubernetes Service. The Ingress's `defaultBackend` names the service; Traefik never sees the request.

**Consequences:**

- **No Authentik forward-auth on Tailscale-exposed services.** A protected service like Open WebUI (which sits behind Authentik on the Cloudflare path) is exposed without authentication on its Tailscale Funnel URL. If you need auth on the Tailscale URL, the service itself must enforce it (OIDC client inside the app, basic auth in the app, etc.).
- **No Traefik middleware.** Rate limiting, header rewriting, CORS rules, retry policies — all bypassed.
- **No HostRegexp matching.** The Tailscale device name + the operator's proxy do the routing; the IngressRoute pattern on the service is irrelevant for the Tailscale URL.
- **Each exposure is independent.** Adding `whoami` exposure doesn't affect `openwebui` exposure. Different proxy pods, different certs, different lifecycle.

**Why this is the right trade-off for the dev-share use case:** the developer running `uis network expose tailscale whoami` is explicitly choosing to make whoami public on the tailnet. "Make it public" is *the request*; if auth was wanted, the dev wouldn't be using Funnel. For the colleague-clicks-Slack-link scenario, Tailscale's job is to provide reachability, not policy enforcement. Cloudflare is the right tool when policy enforcement matters.

**Surfacing this to users matters.** The wizard banner and the future `networking/tailscale.md` guide must call this out — a developer who's used to Authentik-protected `whoami.localhost` will be surprised if `whoami-terje.dog-pence.ts.net` is wide open.

---

## Code state (survey, 2026-05-13)

### Playbooks under `ansible/playbooks/`

| File | Purpose | Reads | Writes | Status |
|---|---|---|---|---|
| `801-setup-network-tailscale-tunnel.yml` | Sets up `tailscaled` on the **provision-host container**, runs a Funnel smoke test, tears it down. | `TAILSCALE_SECRET`, `TAILSCALE_DOMAIN` | Host-side state only, no cluster resources | **Likely obsolete** — see Decision 1 |
| `801-remove-network-tailscale-tunnel.yml` | Removes the cluster Tailscale stack (operator + cluster ingress + per-service ingresses + tailnet devices via API). | OAuth + `TAILNET` + `PUBLIC_HOSTNAME` | Deletes Helm release, ns `tailscale`, per-service ingresses, API devices | Wired as `services.json` `removePlaybook` |
| `802-deploy-network-tailscale-tunnel.yml` | Installs the operator AND creates the public Funnel cluster ingress. | OAuth + `DOMAIN` + `PUBLIC_HOSTNAME` + `OPERATOR_PREFIX` + `TAILNET` | Helm release `tailscale-operator` in ns `tailscale`; `Ingress traefik-ingress` in `kube-system` | Wired as `services.json` `playbook` |
| `802-tailscale-tunnel-addhost.yml` | Creates a Funnel `Ingress` for a named service. | None directly (uses `-e service_name=...`) | `Ingress <service>-tailscale` in `default` | Invoked by `cmd_tailscale_expose` |
| `803-tailscale-device-cleanup.yml` | API-only: deletes stale tailnet devices matching `^<hostname>(-N)?\.` | OAuth + `TAILNET` | Tailnet device deletes via API | Invoked by 803-deletehost script |
| `803-verify-tailscale.yml` | Read-only diagnostic (4 checks). | All six TAILSCALE_* vars | Nothing | Wired into `cmd_tailscale_verify` |
| `805-deploy-tailscale-internal-ingress.yml` | Installs the operator AND creates an **internal** tailnet-only `Service` of class `tailscale`. | OAuth + `DOMAIN` + `OPERATOR_PREFIX` | Helm release `tailscale-operator` (**same name, same ns as 802 — collision**); `Service traefik-tailscale` in `kube-system` | **DELETED in cleanup** (Decision 15) |
| `806-remove-tailscale-internal-ingress.yml` | Removes internal-ingress resources. | None | Deletes `Ingress tailscale-internal-ingress` (**but 805 creates a Service named `traefik-tailscale`, not an Ingress — name mismatch, latent bug**) | **DELETED in cleanup** (Decision 15) |

### Manifests under `manifests/`

| File | Contents | Used by |
|---|---|---|
| `800-tailscale-operator-config.yaml.j2` | Helm values: operator hostname `${TAILSCALE_OPERATOR_PREFIX}-tailscale-operator`, default tags `tag:k8s-operator`. | Both 802 and 805. |
| `803-tailscale-cluster-ingress.yaml.j2` | `Ingress traefik-ingress` with `tailscale.com/funnel: "true"`, hostname `${TAILSCALE_PUBLIC_HOSTNAME}`, backend `traefik:80`. | 802 only. |
| `805-tailscale-internal-ingress.yaml.j2` | `Service traefik-tailscale`, `type: LoadBalancer`, `loadBalancerClass: tailscale`, hostname `${TAILSCALE_OPERATOR_PREFIX}`. | 805 only. **DELETED in cleanup** (Decision 15). |

### Shell wrappers under `networking/tailscale/`

| File | Purpose | Status |
|---|---|---|
| `801-tailscale-tunnel-setup.sh` (31 lines) | Calls 801-setup playbook (the host-side smoke test). | **DELETED in cleanup** (Decision 1). |
| `802-tailscale-tunnel-deploy.sh` (286 lines) | Wraps 802-deploy + 802-addhost. Currently invoked by `cmd_tailscale_expose`. | **DELETED in cleanup** (Decision 8 — its work moves into `up.sh` + `expose.sh`). |
| `803-tailscale-tunnel-deletehost.sh` (189 lines) | Deletes one service's ingress + calls device-cleanup. Currently invoked by `cmd_tailscale_unexpose`. | **DELETED in cleanup** (Decision 8 — its work moves into `unexpose.sh`). |
| `804-tailscale-tunnel-delete.sh` (253 lines) | Comprehensive teardown. Orphaned — superseded by 801-remove playbook. | **DELETED in cleanup** (Decision 4). |

### CLI in `provision-host/uis/manage/uis-cli.sh`

- `cmd_tailscale` (L1934) — dispatcher: `expose | unexpose | verify`
- `cmd_tailscale_expose` (L1970) — calls `802-tailscale-tunnel-deploy.sh <service>`
- `cmd_tailscale_unexpose` (L1981) — calls `803-tailscale-tunnel-deletehost.sh <service>`
- `cmd_tailscale_verify` (L1992) — runs `803-verify-tailscale.yml`
- `cmd_status_summary` (L1571–72) — emits hardcoded `tailscale · port pending` (real per-provider state not yet wired up the way Cloudflare's `cmd_network_status` is)
- Top-level routing at L2557–59; legacy `uis verify tailscale` alias at L1893–95

### `services.json` + service abstraction

`tailscale-tunnel` is a `services.json` entry (lines 512–531) with `playbook: 802-deploy-network-tailscale-tunnel.yml`, `removePlaybook: 801-remove-network-tailscale-tunnel.yml`, `requires: [nginx]`, `helmChart: tailscale/tailscale-operator`, `namespace: tailscale`. Discovered the standard way through `provision-host/uis/services/networking/service-tailscale-tunnel.sh` (36 lines).

Notably, the internal-ingress (805) path has **no service-abstraction entry, no CLI verb, and no docs path**. It can only be triggered via raw `ansible-playbook`. Decision 15 deletes the internal-ingress path; the deleted-files reference lands in `INVESTIGATE-network-tailscale-cross-cluster-backbone.md` for future reference.

### Secrets

Seven `TAILSCALE_*` variables in `secrets-templates/00-common-values.env.template` (lines 64–81):

| Variable | Read by | Path |
|---|---|---|
| `TAILSCALE_SECRET` → `TAILSCALE_VM_AUTH_KEY` | 801-setup (deleted), 803-verify (placeholder check — dropped), 802-deploy.sh (placeholder check — dropped), cloud-init/create-cloud-init.sh (alive — VM bootstrap) | Static auth key for cloud-init / VM bootstrap only — never used cluster-side. Renamed Decision 2. |
| `TAILSCALE_TAILNET` | 801-remove, 802-deploy, 803-device-cleanup, 803-verify, 804-delete.sh | OAuth API device-list URL |
| `TAILSCALE_DOMAIN` | 801-setup, 802-deploy, 803-verify, 805-deploy | Tailnet base domain (e.g. `dog-pence.ts.net`) |
| `TAILSCALE_PUBLIC_HOSTNAME` | 801-remove, 802-deploy, 803-verify, 802-deploy.sh, 804-delete.sh | Funnel ingress device name → `k8s.dog-pence.ts.net` |
| `TAILSCALE_CLIENTID` | 801-remove, 802-deploy, 803-device-cleanup, 803-verify, 805-deploy, 802-deploy.sh | OAuth client ID |
| `TAILSCALE_CLIENTSECRET` | 801-remove, 802-deploy, 803-device-cleanup, 803-verify, 805-deploy, 802-deploy.sh | OAuth client secret |
| `TAILSCALE_OPERATOR_PREFIX` | 802-deploy, 805-deploy | Operator device name prefix + 805 ingress device name |

Plus `BASE_DOMAIN_TAILSCALE` (line 21) — a cross-cutting variable for ingress-route HostRegexp matching, not strictly Tailscale-internal. **DELETED in cleanup** (Decision 16).

**Plus another orphaned variable name in an unused template**: `provision-host/uis/templates/uis.secrets/service-keys/tailscale.env.template` defines `TAILSCALE_AUTH_KEY=""`. No code reads it. **Delete.**

### Variable set after the cleanup (Decisions 1, 2, 3, 11, 12, 13, 16)

Eight variables today → **five** after cleanup (the four cluster-side OAuth values plus the renamed `TAILSCALE_VM_AUTH_KEY` that the cloud-init / VM-bootstrap path keeps using):

| Variable | Status | Source |
|---|---|---|
| `TAILSCALE_CLIENTID` | kept | wizard prompt |
| `TAILSCALE_CLIENTSECRET` | kept | wizard prompt (silent) |
| `TAILSCALE_TAILNET` | kept | wizard prompt |
| `TAILSCALE_OWNER_ID` | renamed from `TAILSCALE_OPERATOR_PREFIX` (Decision 13) | wizard prompt (Decision 14) |
| `TAILSCALE_VM_AUTH_KEY` | renamed from `TAILSCALE_SECRET` (Decision 2) — kept for cloud-init / VM bootstrap | manual edit (cloud-init scope, out of wizard) |
| `TAILSCALE_DOMAIN` | **deleted** (Decision 11, derive from `TAILNET`) | — |
| `TAILSCALE_PUBLIC_HOSTNAME` | **deleted** (Decision 12, derive from `OWNER_ID`) | — |
| `TAILSCALE_AUTH_KEY` (in service-keys template) | **deleted** (Decision 3, no readers ever) | — |
| `BASE_DOMAIN_TAILSCALE` | **deleted** (Decision 16, architecturally vestigial — tailnet domains have no wildcard DNS) | — |

Integration test gate (`provision-host/uis/lib/integration-testing.sh:28`): `tailscale-tunnel:TAILSCALE_CLIENTID,TAILSCALE_CLIENTSECRET,TAILSCALE_DOMAIN` — OAuth path only. The cluster operator path never used `TAILSCALE_SECRET` / `TAILSCALE_VM_AUTH_KEY`, so this gate doesn't need it.

### Docs

- `website/docs/networking/tailscale-setup.md` — Funnel setup guide
- `website/docs/networking/tailscale-internal-ingress.md` — internal (805) setup guide
- `website/docs/networking/tailscale-network-isolation.md` — Funnel security model
- `website/docs/services/networking/tailscale-tunnel.md` — service catalogue entry

---

## Tailscale operator state of the art (verified against current docs, 2026-05-13)

Read against [Tailscale Kubernetes operator docs](https://tailscale.com/kb/1236/kubernetes-operator), [cluster ingress](https://tailscale.com/kb/1439/kubernetes-operator-cluster-ingress), and [Funnel](https://tailscale.com/kb/1223/funnel). Our codebase was last meaningfully touched (PLAN-tailscale-variable-rename) in 2026-02; some things have evolved since.

**Still valid:**

- One operator install per cluster, manages many resources. Our 802+805 collision is still wrong.
- OAuth `CLIENTID` + `CLIENTSECRET` is the canonical auth path. Required scopes: `Devices Core`, `Auth Keys`, `Services` write.
- `Service` with `loadBalancerClass: tailscale` still works for tailnet-only exposure.
- `Ingress` with `tailscale.com/funnel: "true"` is still how you create a Funnel ingress.
- Funnel constraints: ports `443`, `8443`, `10000` only. Let's Encrypt rate limit of 5 certs per hostname per 168h is still real (caused our cluster-tunnel-timeout investigation in 2026-02).

**New since our codebase was written:**

- **`tailscale.com/expose: "true"` annotation on an existing Service** is now the simpler alternative to `Service` with `loadBalancerClass: tailscale`. Both expose the Service to the tailnet; the annotation form doesn't require changing the Service `type`.
- **Workload Identity Federation (beta)** as a second auth path — uses Kubernetes ServiceAccount OIDC tokens instead of long-lived OAuth secrets. Requires the cluster's OIDC discovery endpoints to be publicly accessible (rules out rancher-desktop, viable on AKS).
- **`Ingress` supports multi-backend path-based routing** out of the box (only `Prefix` path type). One Funnel `Ingress` device can route `/` → service-A, `/api` → service-B. Our 803-cluster-ingress.j2 already uses the single-backend form (Traefik does the host routing) — the multi-path option matters for Q7 below.
- **Five new CRDs**: `ProxyClass` (proxy customization), `Connector` (egress / subnet routers / exit nodes), `ProxyGroup` (HA replicas for API-server proxy, beta), `DNSConfig`, `Recorder` (session recording). None are immediately needed for the network-CLI port; `ProxyGroup` becomes interesting if/when we want HA in the cloud.

**Confirmed not deprecated:** the `Service + loadBalancerClass: tailscale` pattern (used by our 805), the `Ingress + tailscale.com/funnel` pattern (used by our 802). No breaking changes flagged in the operator docs as of 2026-01.

---

## Decisions (evidence-supported, lock in for PLAN)

**Decision 1 — Drop `801-setup-network-tailscale-tunnel.yml` and the matching shell wrapper.** Evidence: it sets up `tailscaled` on the provision-host container, runs a smoke test, and tears down — leftover scaffolding from an earlier architecture where the host itself was on the tailnet. The current model puts everything in-cluster via the operator. With 801 gone, the cluster-side has no reader for the static auth-key variable — but the cloud-init / VM-bootstrap path still does, so see Decision 2 for the rename rather than delete.

**Decision 2 — OAuth is canonical for the cluster path; rename `TAILSCALE_SECRET` → `TAILSCALE_VM_AUTH_KEY` for the cloud-init path.** Every cluster-side path (802, 805, 801-remove, verify, device-cleanup) uses `TAILSCALE_CLIENTID` + `TAILSCALE_CLIENTSECRET` (OAuth). The variable historically named `TAILSCALE_SECRET` is a *static auth key* (`tskey-auth-XXX` format) consumed exclusively by the **cloud-init / VM bootstrap path** (`cloud-init/create-cloud-init.sh:85` → `URB_TAILSCALE_SECRET_VARIABLE` substitution in VM templates → VM joins tailnet on first boot). The current name is dangerously ambiguous next to `TAILSCALE_CLIENTSECRET` and obscures that this is for VM provisioning, not the cluster operator. Rename to `TAILSCALE_VM_AUTH_KEY` — scope-explicit, matches Tailscale's own "auth key" terminology. Keep the variable in `00-common-values.env.template` + `00-master-secrets.yml.template` under the new name. Drop the dead reads in `networking/tailscale/802-tailscale-tunnel-deploy.sh:56-57` (placeholder check on a variable the cluster operator path never uses) and `803-verify-tailscale.yml` (verifies a cluster-side key that doesn't exist anymore). The cloud-init / VM-install path itself is out of scope for this initiative and will be revisited separately — that's where the question of "can OAuth replace the static auth key?" gets answered.

**Decision 3 — Delete `TAILSCALE_AUTH_KEY` from `service-keys/tailscale.env.template`.** No code reads it. The same template is unused since the new wizard pattern writes `service-keys/tailscale.env` directly via the init script. Deleting frees the name for the Decision 2 rename target (`TAILSCALE_VM_AUTH_KEY`) without collision — though we use the more scope-explicit name regardless of availability.

**Decision 4 — Delete `networking/tailscale/804-tailscale-tunnel-delete.sh`.** Orphaned (253 lines, no caller); superseded by playbook `801-remove-network-tailscale-tunnel.yml`.

**Decision 5 — Lift the operator install into one canonical step; 802 becomes a pure-data playbook.** The current Helm-release collision (`tailscale-operator` / ns `tailscale` from both 802 and 805) is moot once Decision 15 deletes 805 — but the architectural lift is still right. The cleanup splits into:

- `8XX-tailscale-operator-install.yml` — installs the Helm release, idempotent.
- `802-tailscale-funnel-ingress.yml` — applies the cluster Funnel `Ingress` from 803-cluster-ingress.j2 (only invoked when `up --with-cluster-funnel`).

802 takes a hard dependency on the operator install playbook running first. The 803-cluster-ingress.j2 manifest name is grandfathered for stability; the playbook numbering is fluid.

**~~Decision 6 — Fix the 806 vs 805 resource-name mismatch.~~** — **moot** (Decision 15 deletes both files).

**Decision 7 — Remove `tailscale-tunnel` from `services.json`.** Mirrors the Cloudflare port. Tailscale is a networking provider, not a service. The legacy `uis deploy tailscale-tunnel` becomes `uis network up tailscale` (no mode flag in the default case; `--with-cluster-funnel` is the opt-in flag, per Decisions 9 and 15).

**Decision 8 — Per-service Funnel devices are canonical; port `expose`/`unexpose` into the new namespace.** Per the demo-flow analysis in Positioning above, Tailscale's URL constraint forces per-service devices for any multi-service app. The cleanup ports the existing flow:

- `uis tailscale expose <svc>` → `uis network expose tailscale <svc>` (new sub-verb under the network family)
- `uis tailscale unexpose <svc>` → `uis network unexpose tailscale <svc>`
- `uis tailscale verify` → `uis network verify tailscale`
- `cmd_tailscale` family in `uis-cli.sh` becomes a redirect stub mirroring `cmd_cloudflare` ("`uis tailscale` moved to `uis network ... tailscale`")

**Surviving files** (renamed but preserved):
- `802-tailscale-tunnel-addhost.yml` — per-service Funnel ingress create (keep, possibly rename to clarify it's per-service)
- `803-tailscale-tunnel-deletehost.sh` — per-service ingress delete + device cleanup (keep, possibly fold into a new `unexpose.sh` under `networking/tailscale/scripts/`)
- `803-tailscale-device-cleanup.yml` — unchanged

**Decision 9 — Operator install is one Helm release per cluster; cluster Funnel device is optional opt-in.** The 802/805 Helm-release collision is fixed by lifting the operator install into a dedicated playbook (per Decision 5). The cluster Funnel device (`<owner_id>.<tailnet>.ts.net` from 802-deploy + 803-cluster-ingress.j2) becomes opt-in:

- **Default behavior**: `uis network up tailscale` installs the operator only. Per-service `expose` does the actual exposure work. This saves the Let's Encrypt rate-limit pain that triggered `INVESTIGATE-tailscale-cluster-tunnel-timeout` (5 certs per hostname per 168h) — each per-service device has its own quota, the cluster hostname doesn't burn through testing cycles.
- **Opt-in**: `uis network up tailscale --with-cluster-funnel` deploys the cluster Funnel device on top. Useful for "I want one root URL for the whole cluster" cases — but it's the LE-rate-limited path, so it should be the explicit choice, not the default.

There's only one `up` shape; the variants are flags.

**Decision 10 — Tailscale-exposed services bypass Traefik by design; surface this prominently.** Per the Positioning section, `uis network expose tailscale <svc>` creates a Tailscale operator-managed Ingress whose backend is the service Kubernetes Service directly, not Traefik. This means Authentik forward-auth, Traefik middleware, and HostRegexp matching do not apply on the Tailscale URL. This is inherent to Tailscale's per-service device model — not something we're choosing — but it has security consequences (services that are auth-protected on `whoami.localhost` are *not* auth-protected on `whoami-terje.dog-pence.ts.net`). Users must understand this before exposing services. Implementation contract: the init wizard banner mentions it, `networking/tailscale.md` calls it out in the headline section, and `uis network expose tailscale <svc>` prints a confirmation hint on first use ("This URL will be publicly reachable without Authentik or Traefik middleware. Continue? [y/N]"). See C-8.

**Decision 11 — Drop `TAILSCALE_DOMAIN`; auto-derive from `TAILSCALE_TAILNET`.** For Tailscale's personal/team tailnets, the two values are identical (e.g., both `dog-pence.ts.net`). The codebase reads `TAILSCALE_DOMAIN` for FQDN construction (Funnel device URLs, cert validation hostnames); replace those reads with `TAILSCALE_TAILNET`. Removes one variable, one wizard prompt, one redundant truth.

**Decision 12 — Drop `TAILSCALE_PUBLIC_HOSTNAME`; derive from `TAILSCALE_OWNER_ID`.** The cluster Funnel device name (opt-in via `--with-cluster-funnel`) becomes the owner ID itself — Terje's cluster device is `terje.<tailnet>.ts.net`, Alice's is `alice-imac.<tailnet>.ts.net`. No reason to maintain a second variable; the owner ID *is* the cluster identifier on the tailnet.

**Decision 13 — Rename `TAILSCALE_OPERATOR_PREFIX` → `TAILSCALE_OWNER_ID`.** The old name described its job in `800-operator-config.yaml.j2`; the new name describes what it actually means semantically (the cluster's owner on the shared tailnet). Worth the find-and-replace despite the variable-rename investigation having just touched it — the new semantic justifies the churn.

**Decision 14 — Wizard prompts for `TAILSCALE_OWNER_ID` alongside the other values.** Earlier reading favored config-file-only on the grounds that "the comment block in view explains the identity decision better than a wizard prompt". Reversed: the wizard prompt's explanatory text can carry the same explanation (solo vs team, naming convention, examples), and putting all four required values in one flow is materially better DX than "run wizard, then go edit a file". The wizard now prompts for 4 values: `TAILNET`, `CLIENTID`, `CLIENTSECRET`, `OWNER_ID`. The env file's comment block stays intact (the wizard writes the value, doesn't strip the comment) so users who later inspect the file see the rationale. Re-running the wizard via the Skip/Re-prompt/Show menu (mirrored from cloudflare) lets users change their owner_id later. C-9's empty-owner_id refusal becomes a defensive guard against manual edits leaving the line blank, not a normal-flow expectation.

**Decision 15 — Delete internal-mode (805) entirely.** No active CLI verb invokes it; not in `services.json`; the 806 cleanup is silently broken (resource-name mismatch); no tester/user has surfaced an issue across 50+ talk rounds. Cleanup deletes:

- `ansible/playbooks/805-deploy-tailscale-internal-ingress.yml`
- `ansible/playbooks/806-remove-tailscale-internal-ingress.yml`
- `manifests/805-tailscale-internal-ingress.yaml.j2`
- `website/docs/networking/tailscale-internal-ingress.md`

Modern Tailscale operator patterns for tailnet-only access (`tailscale.com/expose: "true"` annotation, `Connector` CRD, `ProxyGroup`) look nothing like 805's `loadBalancerClass: tailscale on Traefik` approach, so re-implementing later would look fundamentally different anyway. **`INVESTIGATE-network-tailscale-cross-cluster-backbone.md` gets a pointer to the deleted files so the patterns can be recovered from git history** if a future round needs them.

Collapses the strawman: no `--mode=internal` flag, no Q8, no fix-806 work, two `up` shapes instead of three.

**Decision 16 — Delete `BASE_DOMAIN_TAILSCALE` (architecturally vestigial).** The variable exists to support Traefik IngressRoute HostRegexp patterns matching `*.<tailnet-domain>`. After Decision 10 (Tailscale bypasses Traefik for per-service expose) and Decision 15 (no internal-mode), the only remaining Tailscale-through-Traefik path is the opt-in `--with-cluster-funnel` device, which goes to a single hostname (`<owner_id>.<tailnet>.ts.net`) — no wildcard pattern needed. Tailnet domains don't HAVE wildcard subdomain DNS — only registered devices resolve, so a `*.tailnet.ts.net` HostRegexp could never match anything in practice. The variable is a leftover from an earlier mental model where someone imagined wildcard subdomain routing on Tailnet (which doesn't work).

PLAN task: grep all readers of `BASE_DOMAIN_TAILSCALE`. Anything that genuinely needs the tailnet domain string gets `${TAILSCALE_TAILNET}` instead. The rest is deleted. Expected outcome: the variable goes away entirely, including from `00-common-values.env.template` line 21 and `00-master-secrets.yml.template`.

---

## Open questions (PLAN must answer before implementation)

**~~Q1 — How does the user pick a mode?~~** — **resolved by Decisions 9 + 15.** No `--mode` dichotomy. Default `up` installs the operator only; `--with-cluster-funnel` opts into the rate-limited cluster device. Both compose with per-service `expose`.

**~~Q2 — Per-service expose/unexpose: where do they live?~~** — **resolved by Decision 8.** Ported into `uis network expose tailscale <svc>` / `uis network unexpose tailscale <svc>`. Legacy `uis tailscale expose/unexpose` becomes a redirect stub.

**~~Q3 — What's the equivalent of "create the tunnel in Cloudflare dashboard"?~~** — **resolved by Decisions 11–14.** Wizard prompts for four values (in order): `TAILNET`, `CLIENTID`, `CLIENTSECRET`, `OWNER_ID`. `TAILSCALE_DOMAIN` auto-derives from `TAILSCALE_TAILNET`; `TAILSCALE_PUBLIC_HOSTNAME` is deleted (derives from `TAILSCALE_OWNER_ID`). Wizard copy framing uses the developer-tool voice from the Positioning section ("Share your rancher-desktop services through Tailscale Funnel"), not Cloudflare's production framing. Exact banner copy + the dashboard-side prerequisite verbosity (admin console OAuth client + MagicDNS + Funnel nodeAttrs) are PLAN-decision details.

**~~Q4 — Is anyone using the internal-ingress (805) path?~~** — **resolved: dead, delete it** (Decision 15). The cross-cluster backbone investigation gets a pointer to the deleted-files commit so the patterns are recoverable from git history if a future use case needs them.

**~~Q5 — What's the right `up` flow for a brand-new user?~~** — **resolved.** The wizard banner lists all four admin-console prereqs upfront with one-line paths:

```
Before continuing, in the Tailscale admin console (login.tailscale.com):
  1. Settings → OAuth clients → Generate new
     Scopes: Devices Core, Auth Keys, Services (write).
     Copy the Client ID and Client Secret somewhere safe.
  2. DNS → enable MagicDNS (probably already on).
  3. Access controls → ensure 'nodeAttrs' has:
       {"target": ["autogroup:member"], "attr": ["funnel"]}
     (Tailscale auto-adds this on first Funnel attempt; cleaner upfront.)
  4. Confirm you have a Tailscale account / tailnet name visible at the top
     of the admin console (e.g., dog-pence.ts.net).

Full details: /docs/networking/tailscale.md#prerequisites
```

The wizard does **not** validate any of these — they're surfaced for the user to do, and for failure-debugging when something goes wrong later. Validation would require API calls the wizard doesn't have credentials for yet (or even when it does, the complexity isn't worth the upside). Cloudflare lists 3 prereqs in its banner; Tailscale legitimately needs 4. Verbosity is the right trade for "user knows what's wrong when MagicDNS isn't on".

**~~Q6 — Verification target: rancher-desktop with what tailnet?~~** — **resolved: reuse `dog-pence.ts.net`.** The Let's Encrypt rate-limit pain that motivated this question (2026-02 cluster-tunnel-timeout) was concentrated on one hostname. The cleanup uses per-service expose with per-hostname cert quotas — pain doesn't cascade. The only rate-limit-vulnerable hostname is the opt-in `--with-cluster-funnel` device, which isn't the primary verification path. Setting up a fresh tailnet (~30 min ceremony: new OAuth, ACLs, MagicDNS, Funnel nodeAttrs) buys nothing that the existing tailnet doesn't already provide.

**~~Q7 — Cluster Funnel + HostRegexp vs per-service?~~** — **resolved (reversed from earlier read): per-service is canonical** (Decision 8), **cluster Funnel is opt-in** (Decision 9). The demo-flow analysis in Positioning explains why path routing breaks for multi-service apps.

**~~Q8 — `loadBalancerClass: tailscale` vs `tailscale.com/expose` for internal mode?~~** — **moot** (Decision 15 deleted internal-mode entirely). If a future round revives tailnet-only exposure, the annotation form is the modern recommendation — but the design will look fundamentally different from 805 either way.

---

## Strawman target architecture

Updated for Decisions 8, 9, 15 (per-service expose is canonical; cluster Funnel is opt-in; internal-mode deleted).

```
uis network init tailscale                          # wizard: tailnet, clientid, clientsecret, owner_id (4 prompts)
uis network up tailscale                            # operator only — minimum to enable expose (default)
uis network up tailscale --with-cluster-funnel      # adds <owner_id>.<tailnet>.ts.net device (LE-rate-limited; opt-in)
uis network expose tailscale <svc>                  # per-service Funnel → <svc>-<owner_id>.<tailnet>.ts.net
uis network unexpose tailscale <svc>                # remove per-service Funnel + tailnet device cleanup
uis network status tailscale                        # operator + list of exposed services + cluster-funnel state
uis network verify tailscale                        # 5 checks like cloudflare verify
uis network down tailscale                          # remove operator + all per-service devices + optional cluster Funnel
uis network list                                    # tailscale row now real
```

Files in the new tree:

```
networking/tailscale/scripts/
  init.sh         # 4 prompts: TAILNET, CLIENTID, CLIENTSECRET, OWNER_ID
                  # validates OWNER_ID against ^[a-z0-9-]+$ with inline examples
                  # writes service-keys/tailscale.env + patches 00-common-values
  up.sh           # refuses if TAILSCALE_OWNER_ID empty (C-9)
                  # parses --with-cluster-funnel (only mode flag — internal deleted per Decision 15)
                  # chains secrets + operator install (+ optional cluster Funnel ingress)
  down.sh         # removes operator + all per-service devices + (optional) cluster Funnel
                  # preserves env file
  status.sh       # operator status + per-service device list + cluster-funnel state
                  # --summary for `network list`
  verify.sh       # chains 803-verify-tailscale.yml
  expose.sh       # per-service Funnel: wraps 802-tailscale-tunnel-addhost.yml
                  # first-use confirmation prompt about Traefik bypass (C-8)
                  # computes device name: <service>-<TAILSCALE_OWNER_ID>
  unexpose.sh     # per-service Funnel removal: ports the 803-tailscale-tunnel-deletehost.sh flow
```

```
ansible/playbooks/
  8XX-tailscale-operator-install.yml         # NEW: idempotent operator install
  802-tailscale-funnel-ingress.yml           # RENAMED from 802-deploy: just creates the cluster Funnel Ingress (opt-in path)
  802-tailscale-tunnel-addhost.yml           # KEPT (Decision 8): per-service Funnel ingress create
  803-tailscale-device-cleanup.yml           # unchanged
  803-verify-tailscale.yml                   # updated: drop the static-auth-key placeholder check (cluster path uses OAuth only)
  805-tailscale-internal-ingress.yml         # DELETED (Decision 15)
  806-tailscale-internal-ingress-remove.yml  # DELETED (Decision 15 — was broken anyway)
  801-remove-network-tailscale-tunnel.yml    # updated: drops the smoke-test parts left over from old 801-setup days
  # 801-setup-network-tailscale-tunnel.yml: DELETED  (Decision 1)
```

```
networking/tailscale/  (legacy shell wrappers)
  801-tailscale-tunnel-setup.sh:       DELETED  (Decision 1)
  802-tailscale-tunnel-deploy.sh:      DELETED  (its work moves into up.sh + expose.sh)
  803-tailscale-tunnel-deletehost.sh:  DELETED  (its work moves into unexpose.sh)
  804-tailscale-tunnel-delete.sh:      DELETED  (orphan, Decision 4)
```

```
provision-host/uis/services/networking/service-tailscale-tunnel.sh  # DELETED  (Decision 7)
website/src/data/services.json  # tailscale-tunnel entry: REMOVED  (Decision 7)
provision-host/uis/manage/uis-cli.sh:
  cmd_tailscale family            # REPLACED with redirect stub (mirrors cmd_cloudflare):
                                  #   "'uis tailscale' moved to 'uis network ... tailscale'"
                                  #   expose → ./uis network expose tailscale <svc>
                                  #   unexpose → ./uis network unexpose tailscale <svc>
                                  #   verify → ./uis network verify tailscale
  cmd_network                     # add expose, unexpose subcommands
  cmd_network_list                # tailscale row becomes real (reads status.sh --summary)
  cmd_network_up/down/etc         # add tailscale to provider whitelist
```

---

## Implementation contracts (lock in for PLAN)

- **C-1**: `networking/tailscale/scripts/status.sh --summary` emits the same `<state>\t<hint>` format as cloudflare's (states: `not-initialized | configured-not-running | running | unreachable`).
- **C-2**: `networking/tailscale/scripts/up.sh` chains `uis secrets generate && uis secrets apply` before the playbook (same shape as `up.sh` for cloudflare).
- **C-3**: `networking/tailscale/scripts/init.sh` prompts for **four** values in order: `TAILSCALE_TAILNET`, `TAILSCALE_CLIENTID`, `TAILSCALE_CLIENTSECRET`, `TAILSCALE_OWNER_ID`. The owner-id prompt includes an inline explainer (solo vs team naming, example values, charset rule `^[a-z0-9-]+$`, max length 32 chars so `<service>-<owner_id>` fits Tailscale's 63-char device-name limit with room for service names); the wizard validates the input before continuing. Does not prompt for `TAILSCALE_DOMAIN` (auto-derives from `TAILSCALE_TAILNET`; see Decision 11). Writes `.uis.secrets/service-keys/tailscale.env` (mode 0600) AND patches the matching lines in `secrets-config/00-common-values.env.template`. The comment block above each variable in the template stays intact so users who later inspect the file see the rationale.
- **C-4**: `networking/tailscale/scripts/verify.sh` exits 0 only when all five checks pass (Secrets / Network / Operator pods / Ingress(es) / End-to-end HTTPS through Funnel). Matches `cloudflare verify`.
- **C-5**: The cleanup is **rancher-desktop-only** for verification — same scope rule as the Cloudflare port. AKS verification is a follow-up round.
- **C-6**: `cmd_tailscale` (the current `expose`/`unexpose`/`verify` dispatcher) is replaced with a redirect stub on the same shape as `cmd_cloudflare` — prints `'uis tailscale' moved to 'uis network ... tailscale'` plus a sub-hint based on the attempted subcommand (`expose` → `uis network expose tailscale <svc>`, `unexpose` → `uis network unexpose tailscale <svc>`, `verify` → `uis network verify tailscale`), and exits 1. The wizard text in `init.sh` uses the developer-tool framing from the Positioning section (not Cloudflare's production framing).
- **C-7**: `uis network expose tailscale <service>` and `uis network unexpose tailscale <service>` are new sub-verbs under `cmd_network`. They dispatch to `networking/tailscale/scripts/expose.sh` and `unexpose.sh` respectively. `expose.sh` requires the operator to be deployed (calls `up` is **not** automatic — refuses with a pointer if `uis network status tailscale` reports `not-running`). `unexpose.sh` is idempotent: removing a service that isn't exposed is a successful no-op with a clear message. `unexpose.sh` deletes both the in-cluster Ingress AND the corresponding tailnet device via the Tailscale API (preserves today's `803-tailscale-tunnel-deletehost.sh` cleanup behavior so devices don't accumulate as zombies).
- **C-9** (defensive guard): If `TAILSCALE_OWNER_ID` is empty when `uis network up tailscale` (or any verb that produces device names) runs, the command refuses with a clear error. Normal flow shouldn't trigger this — the wizard sets it (Decision 14). The guard catches manual-edit-to-empty, env-file-not-yet-generated, and migrations from older versions:
  ```
  ✗ TAILSCALE_OWNER_ID is not set.

    Re-run the wizard:                   ./uis network init tailscale
    Or edit directly:                    .uis.secrets/secrets-config/00-common-values.env.template

    Examples:
      TAILSCALE_OWNER_ID=terje              # solo
      TAILSCALE_OWNER_ID=terje-imac         # team / multi-machine
  ```
- **C-8**: The "Tailscale bypasses Traefik / Authentik" fact gets surfaced in three places. (1) The `init.sh` banner lists it under "Before you expose anything, know that". (2) The `networking/tailscale.md` user guide opens with a callout block: "Services exposed via Tailscale Funnel bypass Traefik. Authentik forward-auth and other middleware do not apply. The service must enforce its own auth." (3) `expose.sh` prints a one-line confirmation on first use (when no Tailscale-class Ingress exists yet in `default`): "This URL will be publicly reachable without Authentik or Traefik middleware. The service itself must enforce auth if needed. Continue? [y/N]". Subsequent exposures skip the prompt (the user has been told). The prompt can be bypassed with `--yes` for non-interactive use.
- **C-10**: `expose.sh <service>` assumes the named Service lives in `default` namespace on port `80` (matches today's `802-tailscale-tunnel-addhost.yml` behavior). Refuses with a clear error if `kubectl -n default get svc <service>` fails. PLAN may add `--port` / `--namespace` flags for round 1 if a real use case surfaces; otherwise defer to a follow-up round.
- **C-11**: Changing `TAILSCALE_OWNER_ID` (via wizard Re-prompt or manual env-file edit) when the operator is already deployed leaves stale tailnet devices under the old prefix. `up.sh` detects this case: it reads the operator's `Deployment` annotation (or the `urbalurba-secrets` Secret's previous `TAILSCALE_OWNER_ID` value) and refuses if the current env-file value differs:
  ```
  ✗ TAILSCALE_OWNER_ID changed (was: terje, now: terje-imac)
    but operator + exposed services are still running under the old prefix.

    Tear down first, then re-up:
      ./uis network down tailscale
      ./uis network up tailscale
  ```
  This prevents the stale-device accumulation that motivated `INVESTIGATE-tailscale-api-device-cleanup` in 2026-02.

---

## Out of scope for this investigation

- **AKS / multi-node verification.** Same scope rule as the Cloudflare port — verify on rancher-desktop first.
- **Tailscale ACL automation.** Setting up ACL rules in the admin console is a manual prerequisite. The init wizard doesn't drive the Tailscale admin API.
- **MagicDNS configuration.** Required to be enabled at the tailnet level; the wizard doesn't toggle it.
- **Per-platform manifest overrides.** Tailscale operator config is rancher-desktop-tuned today; AKS may want different values. Park for the cloud verification round.

---

## Ready-to-plan checklist

When the PLAN doc gets drafted, it should:

- [ ] Phase the work: secrets cleanup → operator-install split → scripts (up/down/status/verify) → CLI port → per-service expose/unexpose → docs → tester rounds
- [ ] Confirm the redirect-stub wording in `cmd_tailscale` (mirrors `cmd_cloudflare`)
- [ ] PLAN task: grep all readers of `BASE_DOMAIN_TAILSCALE` (Decision 16); rewire or delete per call site

Until those answers land, this stays in backlog.
