---
title: INVESTIGATE — Networking restructure + cloudflared on rancher-desktop
sidebar_label: INVESTIGATE — Networking restructure
---

# INVESTIGATE — Networking restructure + cloudflared on rancher-desktop

**Status:** Completed (2026-05-16)

**All 10 decisions and 4 threads shipped.** Implementation landed across PRs #169–#172; produced plan `PLAN-network-cloudflare-port-and-docs-lift-up.md` was closed in PR #190 (see `completed/`). The Tailscale follow-up referenced below (`INVESTIGATE-tailscale-architecture-cleanup.md`) is also completed — see PLAN-002 + PLAN-003 in `completed/`.

**Decisions** (2026-05-12):

- **Scope tightened**: Cloudflare-only port + Cloudflare-only verification + docs lift-up. **Tailscale is deferred wholesale to a separate plan** (`INVESTIGATE-tailscale-architecture-cleanup.md`, future). Threads 2 and 3 still apply but only register `cloudflare` as a network provider.
- **Q1 = C** — verification on **rancher-desktop** with the real `*.skryter.no` domain pointed at a Cloudflare tunnel. €0, local. Rancher-desktop is the **only** verification target this round; other platforms are not in scope.
- **Q2 = yes** — fix the replica-count comment mismatch and the placeholder-detection bug as part of the Thread 1/2 PR (they live in the same files).
- **Q3 = A** — `uis network <verb> <provider>` symmetric with `uis platform <verb> <provider>`. Same six verbs: `list / init / up / status / down / verify`.
- **Q4 = no** — no `uis network use`. Cloudflare + Tailscale (when Tailscale is ported later) can coexist on one cluster; there's no "active provider" to switch between.
- **Q5 = B** — remove `cloudflare-tunnel` from `services.json`. Single entry point via `uis network`. Leave `tailscale-tunnel` in services.json untouched until the Tailscale cleanup plan.
- **Q6 = defer** — Tailscale 802/805 operator collision is a Tailscale architecture problem; goes into the future Tailscale cleanup plan.
- **Q7 = defer** — Tailscale secret-naming mess. Same plan as Q6.
- **Q8 = A** — Networking promoted to sidebar position 4, right after Platforms.
- **Q9 = A** — Consolidate `services/networking/` into `networking/`. Single tree.
- **Q10 = A** — Move Traefik out of `services/networking/` to `networking/traefik.md`.

**Sequencing**:
1. **Thread 2 (Cloudflare CLI port)** — build `cmd_network_*` family in `uis-cli.sh` + new `cloudflare.env` template variables + remove `cloudflare-tunnel` from `services.json` + fix replica + placeholder bugs.
2. **Thread 1 verification (via the new CLI)** — on rancher-desktop with `*.skryter.no`. `uis network init cloudflare` → `uis network up cloudflare` → `curl https://something.skryter.no`.
3. **Thread 3 docs lift-up** — sidebar move + consolidate trees + Traefik move + rewrite `networking/index.md` as the hub + write `networking/cloudflare.md` as the novice walkthrough.
4. **Followup plan** (`INVESTIGATE-tailscale-architecture-cleanup.md`) — solves 802/805 collision + secret-naming mess + ports Tailscale to `uis network <verb> tailscale`. Out of scope this round.

---

## Status: Backlog (historical — original framing before decisions locked)

**Goal**: Three interlocking threads, with **priority on Thread 1**:

1. **🔥 Priority — cloudflared running in-cluster on rancher-desktop with a real Cloudflare-managed domain.** The local cluster is the verification target this round; other platforms are explicitly out of scope. Proves the deploy + tunnel-up + Traefik routing mechanic works end-to-end via the real internet path.
2. **CLI shape port — bring `uis cloudflare` to the `uis <verb>` mental model.** Today it's a top-level verb without a unifying umbrella. Cloudflare-only port this round; Tailscale port deferred to a separate plan because its underlying playbooks have genuine architectural issues (802/805 operator collision, secret-name mess) that need their own design round, not a rushed port.
3. **Docs lift-up — Networking promoted in the sidebar, just like Platforms.** Plus consolidation of the two parallel doc trees (`services/networking/` and `networking/`).

**Last Updated**: 2026-05-12

**Depends on**: AKS docs PR (#168 merged) — platforms work is the model this work follows. F14/F15/F16/F17/F18 closed (mechanics on which the networking deploy relies).

**Out of scope** (this round):
- Service mesh, in-cluster east-west traffic. This is *external-traffic-to-cluster* only.
- Other platforms. The verification target is rancher-desktop, and only rancher-desktop. AKS or any other platform isn't in this round, isn't documented as "coming next", isn't referenced.
- Tailscale anything. Deferred wholesale to a future `INVESTIGATE-tailscale-architecture-cleanup.md`.
- New networking providers beyond Cloudflare (Tailscale being the only other one, deferred above).
- Ingress controller rewriting. Traefik stays.
- The Cloudflare legacy paths under `networking/cloudflare/legacy/` (already deprecated, README acknowledges).

---

## Framing — networking is the next "lift-up", with genuine architecture bumps in the way

Multi-platform was the headline for the previous round. Multi-networking is a smaller axis but the same shape would apply if we promote it. Crucially, **the current networking subsystem has real architectural issues that the platform work didn't have** — Thread 2 can't be a pure UX port. It needs to fix real bugs.

The framing question: **does networking need its own first-class structural slot — alongside services and platforms — *and* do we fix the underlying playbook/secret mess as part of the same round, or in a separate round?**

---

## Current state — what exists today (revised after direct read)

### CLI surface

```
uis tailscale expose <service>      # routes to networking/tailscale/802-tailscale-tunnel-deploy.sh <service>
uis tailscale unexpose <service>    # routes to networking/tailscale/803-tailscale-tunnel-deletehost.sh
uis tailscale verify                # ansible 803-verify-tailscale.yml

uis cloudflare verify               # ansible 822-verify-cloudflare.yml
uis cloudflare teardown             # ansible 821-remove-network-cloudflare-tunnel.yml + dashboard hints
uis deploy cloudflare-tunnel        # service-shaped deploy → 820-deploy playbook
uis undeploy cloudflare-tunnel      # service-shaped undeploy
uis deploy tailscale-tunnel         # service-shaped deploy → 802-deploy playbook (operator + optional cluster ingress)
```

Three patterns coexist for networking:
- `uis tailscale <verb>` (per-provider top-level verb routing to shell scripts under `networking/tailscale/`).
- `uis cloudflare <verb>` (per-provider top-level verb routing to ansible playbooks).
- `uis deploy <service>` (treats `cloudflare-tunnel` and `tailscale-tunnel` as services in `services.json`).

### Cloudflare deployment (token-based, in-cluster)

`uis deploy cloudflare-tunnel` invokes `ansible/playbooks/820-deploy-network-cloudflare-tunnel.yml`:
1. Reads `CLOUDFLARE_TUNNEL_TOKEN` from `urbalurba-secrets`.
2. `kubectl apply -f manifests/820-cloudflare-tunnel-base.yaml`.
3. Waits for the pod to roll out.
4. Smoke-tests through the tunnel.

The manifest is a single Deployment with **`replicas: 1`**. The playbook header comment claims "**2 replicas of cloudflared**". One of the two is wrong — manifest is the source of truth, comment is stale. Cosmetic but real.

### Tailscale deployment (operator + per-service ingress)

Two patterns deploy a Tailscale operator:

- **`802-deploy-network-tailscale-tunnel.yml`** (the "tunnel" path) — Helm-installs `tailscale/tailscale-operator` in namespace `tailscale` with release name `tailscale-operator`. Reads `TAILSCALE_CLIENTID` + `TAILSCALE_CLIENTSECRET` + `TAILSCALE_TAILNET` (OAuth-style). Auto-cleans stale devices via the API. If invoked with a service name (via `802-tailscale-tunnel-deploy.sh <svc>`), also creates a per-service Funnel ingress for that service.
- **`805-deploy-tailscale-internal-ingress.yml`** (the "internal-ingress" path) — Helm-installs `tailscale/tailscale-operator` in namespace `tailscale` with release name `tailscale-operator`. **Same Helm release name. Same namespace.** Reads `TAILSCALE_CLIENTID` + `TAILSCALE_CLIENTSECRET`. Then creates a `LoadBalancer` Service (not an Ingress, despite the name) for in-tailnet-only access.

**This is a genuine collision risk.** Running 802 then 805 (or vice versa) will Helm-upgrade the same release; whichever ran last wins. There's no documented contract about ordering or mutual exclusion. The operator config might differ between the two, in which case the second run silently drops the first's config.

Add to that, **`801-setup-network-tailscale-tunnel.yml`** is a *third* playbook in the family — it's a pre-deploy validation step ("does urbalurba-secrets have TAILSCALE_SECRET set?"). Confusingly, it reads `TAILSCALE_SECRET` (a *different* secret name) while the actual deploys read `TAILSCALE_CLIENTID`/`TAILSCALE_CLIENTSECRET`. The 801 check passes if `TAILSCALE_SECRET` is present and non-empty; the 802 deploy then ignores that var and reads the OAuth pair instead. The validation gate doesn't validate what the deploy actually needs.

### Tailscale secret naming, in full

| Var | Where it's read | Where it's set |
|---|---|---|
| `TAILSCALE_AUTH_KEY` | nowhere (in playbooks/scripts) | `tailscale.env.template` (the **only** var in the template the user is told to set) |
| `TAILSCALE_SECRET` | `801-setup` validation only | nowhere documented |
| `TAILSCALE_CLIENTID` | `802-deploy` + `805-deploy` | nowhere documented |
| `TAILSCALE_CLIENTSECRET` | `802-deploy` + `805-deploy` | nowhere documented |
| `TAILSCALE_TAILNET` | `802-deploy` (for API device cleanup) | nowhere documented |

This is the most surprising finding from the survey: **the user-facing env template doesn't match the actual deploy requirements**. A user following the template will set `TAILSCALE_AUTH_KEY` (the value the template asks for); the deploy will look for `TAILSCALE_CLIENTID` + secret + tailnet (which the template doesn't mention); 801-setup will accept the deploy as long as `TAILSCALE_SECRET` is set (which the template also doesn't mention).

How this works in practice today: undocumented out-of-band mechanism. Either docs not surveyed in this round have the full story, or this works only because someone hand-edited `urbalurba-secrets` once with all the right keys.

### `networking/tailscale/` shell scripts

Four scripts, **not in `legacy/`**, all current:

- `801-tailscale-tunnel-setup.sh` (30 lines) — wraps the 801 ansible playbook
- `802-tailscale-tunnel-deploy.sh` (285 lines) — wraps the 802 ansible playbook + handles the "no-arg deploys operator, with-arg adds service" duality
- `803-tailscale-tunnel-deletehost.sh` (188 lines) — removes a specific service's ingress
- `804-tailscale-tunnel-delete.sh` (252 lines) — full Tailscale operator teardown

These are the "pre-UIS-CLI" scripts. `uis tailscale expose <svc>` shells out to 802 with a service arg; `uis tailscale unexpose <svc>` shells out to 803. There's no `uis tailscale delete` despite 804 existing — to fully tear down the operator, you'd need to invoke the script directly or via a service-undeploy path. Inconsistent.

### Documentation today

| Location | Content | Status |
|---|---|---|
| `website/docs/networking/index.md` (411 lines) | **Already a de facto hub page** — architecture overview, dual-tunnel comparison, decision tree | Mostly there; needs alignment with new CLI shape |
| `website/docs/networking/cloudflare-setup.md` (312) | Operator setup guide (token-based, 15-20 min) | Current; assumes manual `uis deploy cloudflare-tunnel` |
| `website/docs/networking/tailscale-setup.md` (443) | Operator setup guide | Current; pre-CLI-shape |
| `website/docs/networking/tailscale-internal-ingress.md` (292) | The 805 path docs | Specific use case |
| `website/docs/networking/tailscale-network-isolation.md` (314) | Patterns doc | Architecture deep-dive |
| `website/docs/services/networking/index.md` (24) | Stub index | Almost empty |
| `website/docs/services/networking/cloudflare-tunnel.md` (107) | Service catalog entry | Cross-refs to `networking/` |
| `website/docs/services/networking/tailscale-tunnel.md` (107) | Service catalog entry | Cross-refs to `networking/` |
| `website/docs/services/networking/traefik.md` (70) | Traefik reference | Functionally networking-infra, not a service |

`networking/index.md` is already substantial (411 lines) — closer to a hub than the platforms work started with. The lift-up is more about sidebar position + cross-tree consolidation than writing a new hub from scratch.

### Multi-cluster targeting status

- **Cloudflare playbooks**: read `kubeconfig_file: "/mnt/urbalurbadisk/.uis.secrets/generated/kubeconfig/kubeconf-all"` (the legacy bind-mount path). PR #163/#164 makes that path lockstep-correct after `pf_lockstep_flip` — so cloudflare-tunnel deploys to the active platform, same as nginx (verified end-to-end on AKS in talk49).
- **Tailscale 802-deploy**: same path. ✓ AKS-safe.
- **Tailscale 801-setup, 802-tailscale-tunnel-deploy.sh, 803**: mix of kubectl-without-context and `--context $target_host`. Inconsistency — most invocations work because the active kubectl context happens to be the active platform anyway (post `pf_lockstep_flip`), but the lockstep isn't enforced. A bug here would surface as "verify works on rancher-desktop but not on AKS" type weirdness.

---

## Thread 1 — 🔥 Cloudflared running in-cluster on rancher-desktop with `*.skryter.no`

### What we already know

- Cloudflared in-cluster deployment is **already token-based + manifest-driven** (post-legacy refactor).
- It works on rancher-desktop today via `uis deploy cloudflare-tunnel` (documented in `networking/cloudflare-setup.md`).
- The user owns `skryter.no` on Cloudflare and has a pre-configured tunnel that routes `*.skryter.no` to the local rancher-desktop cluster — so the verification can use a real public domain with a real internet path without any per-test domain registration ceremony.

### Real bugs in the existing path (surfaced by the direct read)

- **Replica count cosmetic**: manifest says `replicas: 1`, playbook header comment says "2 replicas". Pick one and align. Platform-agnostic — would surface on any cluster.
- **Placeholder detection logic**: 820-deploy's check compares `CLOUDFLARE_TUNNEL_TOKEN` against the string `"your-cloudflare-tunnel-token"`, but the cloudflare.env.template ships `CLOUDFLARE_TUNNEL_TOKEN=""` (empty string, not that literal placeholder). **Empty tokens aren't caught.** Real bug, fix the comparison to detect both empty and the literal placeholder.

### Questions

#### Q1 — What gets verified, and how?

The verification target is **rancher-desktop**, with the user's existing `*.skryter.no` tunnel. Three scope options:

- **A. End-to-end domain flow**: full `networking/cloudflare-setup.md` walkthrough on rancher-desktop — register a domain in Cloudflare from scratch, generate a token, run `uis deploy cloudflare-tunnel`, reach `https://<service>.<domain>` from a public browser. ~15-20 min, requires registering a new domain in the round.
- **B. Pod-up-and-tunnel-registered**: spin up the manifest with a stub token, verify the pod starts, cloudflared logs show "Connection registered" with Cloudflare edge. No real domain needed, doesn't verify the routing-through-Traefik half.
- **C. Real domain happy path**: use the user's pre-existing `*.skryter.no` tunnel — token already exists in their Cloudflare dashboard, pointing at this local rancher-desktop cluster. `uis network init cloudflare` collects the token, `uis network up cloudflare` deploys, deploy a test service, curl from public (mobile data) reaches `https://<svc>.skryter.no` end-to-end.

**Decision = C** — verifies the genuine happy path (cloudflared → Cloudflare edge → public → curl → Traefik → service in cluster) without per-test domain ceremony. ~30 min, €0.

#### Q2 — Fix the replica/placeholder cosmetics in the same PR?

Two real bugs surface above. Both are small and live in the same file family the CLI port will touch. **Decision = yes, fix in the Thread 1/2 PR.**

---

## Thread 2 — CLI shape port (Cloudflare only this round)

Thread 2 builds `uis network <verb> <provider>` symmetric with `uis platform <verb> <provider>`. **This round only registers `cloudflare` as a provider.** The Tailscale port is deferred to a separate plan because Tailscale's underlying playbooks have real architectural issues that deserve their own design round, not a rushed bundling.

### Tailscale issues — deferred to a follow-up plan

The direct read surfaced two Tailscale-specific bugs that are NOT solved in this round:

- **Tailscale operator collision** (802 vs 805). Both Helm-install `tailscale-operator` in namespace `tailscale` with the same release name. Sequential runs are destructive. Solving means rename, consume-not-reinstall, or collapse-into-one.
- **Tailscale secret naming mismatch**. Template ships `TAILSCALE_AUTH_KEY`; `801-setup` validates `TAILSCALE_SECRET`; `802/805-deploy` read `TAILSCALE_CLIENTID`/`TAILSCALE_CLIENTSECRET`/`TAILSCALE_TAILNET`. The user-facing template doesn't list what the deploy actually needs.

Both are recorded in this investigation (Q6 and Q7 below). Both have `Decision = defer` to `INVESTIGATE-tailscale-architecture-cleanup.md`. Until that plan is written + shipped, `uis tailscale expose/unexpose/verify` and `uis deploy tailscale-tunnel` stay as-is; `uis network up tailscale` is **not** wired this round.

### Cloudflare-specific cleanup folded into this round

Two small Cloudflare-side bugs surfaced (item D from the earlier draft):

- **Replica count mismatch**: manifest says 1, playbook header comment says 2.
- **Placeholder detection logic**: empty token isn't caught (Q1 / Q2 above).

Both small. Fixed in this round's PR.

### CLI surface questions

#### Q3 — Umbrella shape?

- **A. `uis network <verb> <provider>`** (symmetric with `uis platform`): `list / init / up / status / down / verify`. Wide.
- **B. `uis network <provider> <verb>`** (provider-first).
- **C. Status quo**: `uis tailscale` and `uis cloudflare` stay top-level verbs.

**Decision = A**. Symmetry with `uis platform <verb> <provider>` carries the mental model. Provider-specific operator actions like Tailscale's `expose <service>` can land later (when Tailscale is ported) as additional verbs in the same shape — `uis network expose tailscale <service>` reads fine.

#### Q4 — Is "active provider" meaningful?

For platforms it absolutely is (exactly one active at a time). For networking:
- Cloudflare exposes all services with IngressRoutes via one tunnel.
- Tailscale (when ported later) exposes services individually (one pod per exposed service).
- **They can coexist** — same cluster running both Cloudflare for public domains + Tailscale for internal.

**Decision = no `uis network use`. `uis network list` is meaningful** (what's deployed and reachable), but switching isn't.

The `uis network list` output for this round shows two rows: `cloudflare` (real state from the new CLI) and `tailscale` (state hint `CLI port pending — use 'uis tailscale ...' for now`). When the Tailscale cleanup plan ships, the tailscale row gets real state.

#### Q5 — Does cloudflare-tunnel stay a service?

`uis deploy cloudflare-tunnel` works today via the services.json entry. If `uis network up cloudflare` ships, do we keep both?

- **A. Keep both as aliases** — `uis deploy cloudflare-tunnel` continues to work, `uis network up cloudflare` is the canonical entry point.
- **B. Remove from services.json** — single canonical entry point.

**Decision = B**. Symmetric with platforms (you don't `uis deploy azure-aks`, you `uis platform up azure-aks`). Single entry point keeps the framing clean.

After removal, `uis deploy cloudflare-tunnel` errors with `service not found` plus a hint pointing at `uis network up cloudflare`. `tailscale-tunnel` stays in services.json untouched until the Tailscale cleanup plan ports it the same way.

#### Q6 — Solve the 802/805 Tailscale operator collision now?

Real Tailscale bug. Two paths:
1. **Solve in this round**: rename one release, or refactor 805 to consume 802's operator. Tailscale architecture work.
2. **Defer to a separate plan**: 805 stays as-is, this round doesn't touch Tailscale code.

**Decision = defer**. Goes into `INVESTIGATE-tailscale-architecture-cleanup.md` (stub created in this round's PLAN Phase 7). Solving it right means Tailscale architecture redesign, not a port.

#### Q7 — Solve the Tailscale secret-naming mismatch now?

Same shape as Q6. Real bug, Tailscale-specific.

**Decision = defer**. Same follow-up plan as Q6. The Tailscale env template + setup guide stays as-is until the cleanup plan ports them.

Lean: **A**. OAuth credentials are the supported Tailscale auth path for operator-style deployments; the template is just out of date. A 4-line template update + setup-guide refresh closes it.

---

## Thread 3 — Docs lift-up

### What we know

- `networking/index.md` is already 411 lines — closer to a hub than the platforms work started with. The lift-up here is sidebar position + cross-tree consolidation, not new-page writing.
- `services/networking/*.md` cross-refs `networking/*.md` already. The split is functional (catalog entries vs setup guides), not random — but a novice doesn't care about the distinction.
- `services/networking/traefik.md` describes infrastructure that *every* `uis platform up` installs. It's not a deployment choice the user makes.

### Questions

#### Q8 — Sidebar position?

- **A.** Position 4, right after `Platforms` (which is at position 3 after the platform work). Infrastructure-y concepts cluster together.
- **B.** Position 5, after `Services`. Networking is "how to expose services", follows services in reading order.
- **C.** Stay nested under `Services` — only add a top-level pointer.

Lean: **A**. Reading order is "Getting Started → Platforms (where) → Networking (how to reach) → Services (what to run)".

#### Q9 — Consolidate the two doc trees?

- **A.** Move all `services/networking/*` content into `networking/`. Single tree.
- **B.** Keep both, document the split, hub page resolves it.

Lean: **A**. The split is historical, not user-facing.

#### Q10 — Move Traefik out of `services/`?

- **A. Move to `networking/traefik.md`** — alongside Cloudflare/Tailscale providers.
- **B. Stay in `services/networking/traefik.md`** — Traefik is technically a deployment.

**Decision = A**. Traefik isn't optional; every platform installs it on `up`. Treating it as a service implies a choice that isn't there.

---

## Implementation contracts (post-decision details)

Small calls the PLAN needs to follow that aren't load-bearing enough for their own Q-block:

- **`uis network list` row format**: same shape as `uis platform list`. Two rows this round:
  - `cloudflare   <state>   <hint>` — real state from a new `platforms/...`-style per-provider `status.sh --summary` (the four-state enum: `not-initialized` / `configured-not-running` / `running` / `unreachable`).
  - `tailscale    · port pending   (use './uis tailscale expose/unexpose/verify' for now)` — placeholder row so Tailscale stays visible from the new hub.
- **`uis network init cloudflare` wizard fields**: prompts for `CLOUDFLARE_TUNNEL_TOKEN` (the only required field). Optionally prompts for `CLOUDFLARE_ACCOUNT_ID` / `CLOUDFLARE_ZONE_ID` only if the 822-verify playbook requires them (PLAN reads the playbook to confirm). Writes to `.uis.secrets/service-keys/cloudflare.env`; shows host-relative path in the success line.
- **`uis deploy cloudflare-tunnel` after removal**: errors with `service not found` followed by a hint pointing at `./uis network up cloudflare`.
- **Banner walk-out, symmetric with platforms**: the `_uis_cluster_banner` helper fires on cluster-touching subcommands (`up / down / verify`) and stays walked-out of discovery/config subcommands (`list / init / status`). Same catch-22 reasoning as `cmd_platform_list/use`.
- **`uis network status cloudflare` cost note**: Cloudflare's free tier covers personal/small use; the status panel mentions this rather than a per-day estimate (Cloudflare doesn't bill per running pod the way AKS does).
- **Networking hub `How it works` subsection**: mirror the cluster-targeting subsection on `platforms/index.md`. Networking operations target the active platform (via `pf_active_platform` / `target_host`); the hub explains this briefly.
- **Existing 411-line `networking/index.md` content**: the architecture overview (dual-tunnel comparison, decision tree, how-it-works) is already substantive. PLAN preserves these sections, rewrites the lead + adds the `uis network <verb>` content + cross-link table. Don't trash the existing material; refactor around it.

---

## Suggested next step

User reviews threads + Q1–Q10. Decisions are locked above. Recommended sequencing (smallest path forward):

1. **Thread 2 (Cloudflare CLI port) first** — builds the new entry point users will rely on, including the small Cloudflare bug fixes (replica + placeholder).
2. **Thread 1 verification (via the new CLI)** — on rancher-desktop with `*.skryter.no`. Verifies the new CLI + cloudflared-in-cluster in one round.
3. **Thread 3 docs lift-up** — sidebar move + tree consolidation + Traefik move + hub rewrite + Cloudflare novice page. Pure docs, can land in same PR.
4. **Followup plan** (`INVESTIGATE-tailscale-architecture-cleanup.md`) — solves 802/805 collision + secret-naming mess + ports Tailscale to `uis network <verb> tailscale`. Out of scope this round; stub created in this round's PLAN.

The priority is rancher-desktop cloudflared with the real `*.skryter.no` domain. Other platforms are not in scope.
