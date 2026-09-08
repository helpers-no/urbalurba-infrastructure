---
title: PLAN — Cloudflare network port + docs lift-up
sidebar_label: PLAN — Cloudflare network port + docs lift-up
---

# PLAN — Cloudflare network port + docs lift-up

**Status:** Completed (work shipped piecemeal across PRs #169–#172)

---

## Close-out retrospective (2026-05-15)

The plan was never executed as a single unified "execute" PR — the deliverables landed across PRs #169–#172 instead. State of each phase:

| Phase | State | Evidence |
|---|---|---|
| 1 — `cmd_network_*` family | ✓ Done | `provision-host/uis/manage/uis-cli.sh` has `cmd_network` dispatcher with init/list/up/status/down/verify/expose/unexpose. |
| 2 — Remove cloudflare-tunnel from services.json | ✓ Done | `website/src/data/services.json` no longer lists `cloudflare-tunnel`. |
| 3 — Small Cloudflare bugs from survey | ✓ Done | Bugs surfaced during the port shipped alongside Phase 1. |
| 4 — Verification on rancher-desktop / `*.skryter.no` | ✓ Done | Verified end-to-end against the `*.skryter.no` tunnel during the port-PR rounds. |
| 5 — Docs lift-up | ✓ Done | `networking/cloudflare.md` + `cloudflare-setup.md` rewritten on `uis network` flow; legacy `uis deploy cloudflare-tunnel` / `uis cloudflare verify/teardown` refs swept in PR #185. |
| 6 — Tester verification round | ✓ Done | Covered alongside the port-PRs; closed end-to-end on `*.skryter.no`. |
| 7 — Tailscale follow-up plan stub | ✓ Done | Tailscale work shipped via PLAN-002 + PLAN-003 (both completed). |

---

**Spec**: [INVESTIGATE-network-cloudflare-in-cluster-restructure.md](INVESTIGATE-network-cloudflare-in-cluster-restructure.md) — Q1-Q10 locked in.

**Goal**: Port Cloudflare networking from the current ad-hoc shape (`uis deploy cloudflare-tunnel` + `uis cloudflare verify/teardown` + manual setup-guide-driven dashboard work) to a first-class `uis network <verb> cloudflare` command family symmetric with `uis platform <verb> <provider>`. Lift `Networking` in the sidebar + docs. **Tailscale wholesale deferred** to a future plan.

**Verification target**: rancher-desktop with the real `*.skryter.no` Cloudflare tunnel. €0, local. Rancher-desktop is the **only** target this round.

**Out of scope**:
- Tailscale anything. Operator collision (802/805), secret-naming mess, CLI port for tailscale — all deferred to `INVESTIGATE-tailscale-architecture-cleanup.md` (future). For this round, leave `uis tailscale expose/unexpose/verify` + `tailscale-tunnel` in services.json untouched.
- Other platforms. The goal is "cloudflared running on rancher-desktop with the real domain". Verification on any other platform (AKS, etc.) is **not in this round**; it's not even a coming-next step. Don't reference it in the docs.
- New Cloudflare features (DNS-as-code via API token, multi-tunnel, etc.). Just port what exists today.

---

## Phases

### Phase 1 — `cmd_network_*` family in `uis-cli.sh`

Mirror `cmd_platform_*` shape. New subcommands routed under `uis network <verb> <provider>`.

- [ ] **1.1** Add the dispatch + help block. Subcommands: `list / init / up / status / down / verify`. Provider arg: `cloudflare` (only registered provider for now; `tailscale` will join later via the cleanup plan).
- [ ] **1.2** `cmd_network_list` — show all providers UIS knows about + their state. Row format mirrors `uis platform list`:
  ```
  PROVIDER     STATUS
  cloudflare   <icon> <state>            (<hint>)
  tailscale    · port pending            (use './uis tailscale expose/unexpose/verify' for now)
  ```
  - **Cloudflare row** — real state from a new `networking/cloudflare/scripts/status.sh --summary` (same shape as the per-platform `status.sh --summary` in `platforms/azure-aks/scripts/`). Four states:
    - `· not initialized` — `.uis.secrets/service-keys/cloudflare.env` missing
    - `· configured, not running` — env present but no Deployment in the cluster
    - `✓ running` — Deployment present + pod Ready + tunnel logs show "Connection registered"
    - `✗ unreachable` — Deployment present but pod not Ready, or no recent successful connection
  - **Tailscale row** — fixed placeholder string (no real probe this round). Keeps Tailscale visible in the new hub without pretending it's been ported.
- [ ] **1.3** `cmd_network_init <provider>` — interactive wizard. For cloudflare:
  - Detect existing `.uis.secrets/service-keys/cloudflare.env`. If present, offer (1) skip — keep current values, (2) re-prompt — overwrite, (3) show — print current values + path.
  - Prompt for **`CLOUDFLARE_TUNNEL_TOKEN`** (the only required field). Paste-from-Cloudflare-dashboard. Reject empty input.
  - Read `ansible/playbooks/822-verify-cloudflare.yml` first to determine whether `CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID` / `CLOUDFLARE_ZONE_ID` are actually consumed; only prompt for ones that are. (Don't prompt for vars no playbook reads — that's the secret-name-mess pattern we want to avoid.)
  - Write the env file to `.uis.secrets/service-keys/cloudflare.env`. Show **host-relative path** in success line — `✓ Config: .uis.secrets/service-keys/cloudflare.env`. Closing `Next:` hint: `./uis network up cloudflare`.
- [ ] **1.4** `cmd_network_up <provider>` — chain script. For cloudflare:
  - Validate prerequisites (env file present, token non-empty, kubeconfig context reachable, urbalurba-secrets applied).
  - Trigger `uis secrets apply` if needed so `CLOUDFLARE_TUNNEL_TOKEN` lands in the `urbalurba-secrets` K8s secret.
  - Invoke the existing `ansible/playbooks/820-deploy-network-cloudflare-tunnel.yml` playbook.
  - Closing banner shows the tunnel ID + the cluster + an `Active platform` line + smoke-test result.
- [ ] **1.5** `cmd_network_status <provider>` — show cluster state, tunnel state, pod health, last logs (or pointer to verify). For cloudflare specifically:
  - **Cost note**: `Cloudflare's free tier covers personal/small use. No per-pod billing — unlike AKS, you don't need to "tear down to save money".` (Mention cost framing rather than a per-day estimate; Cloudflare doesn't bill per running pod.)
  - Active platform line so the user knows which cluster the cloudflared pod is on.
- [ ] **1.6** `cmd_network_down <provider>` — wrap the existing `ansible/playbooks/821-remove-network-cloudflare-tunnel.yml`. Show dashboard cleanup hints in the closing banner. Preserve the env file by default (symmetric to `uis platform down` preserving the platform env file).
- [ ] **1.7** `cmd_network_verify <provider>` — wrap the existing `ansible/playbooks/822-verify-cloudflare.yml`. Same as today's `uis cloudflare verify`.
- [ ] **1.8** Apply the banner (`_uis_cluster_banner`) to `cmd_network_up`, `cmd_network_down`, `cmd_network_verify` — each touches the cluster and should announce which platform it's targeting. **Walk it out** of `cmd_network_list / init / status` for the same catch-22 reason it's walked out of `cmd_platform_list / use`: `list` IS the discovery command (banner-then-abort makes it useless when the user has no active context), `init` doesn't touch the cluster at all (just writes a local env file), `status` answers "is this provider running?" which a banner-abort would short-circuit.
- [ ] **1.9** Update `cmd_help`'s help block — add the `Network:` section between `Platform:` and `Services:`.

### Phase 2 — Remove cloudflare-tunnel from services.json

- [ ] **2.1** Delete the `cloudflare-tunnel` entry from `website/src/data/services.json` (and any other services.json copies — grep the repo).
- [ ] **2.2** Delete `provision-host/uis/services/networking/service-cloudflare-tunnel.sh` (the service-shaped wrapper).
- [ ] **2.3** Leave `tailscale-tunnel` + `service-tailscale-tunnel.sh` untouched.
- [ ] **2.4** Verify `uis list` no longer shows `cloudflare-tunnel`. `uis deploy cloudflare-tunnel` should error with:
  ```
  [ERROR] Service 'cloudflare-tunnel' not found.
          Cloudflare moved to './uis network up cloudflare' — see './uis help' for the Network section.
  ```
  The redirect makes the transition discoverable for users with muscle memory.

### Phase 3 — Fix the small Cloudflare bugs surfaced by the survey

- [ ] **3.1** `manifests/820-cloudflare-tunnel-base.yaml` says `replicas: 1`; `ansible/playbooks/820-deploy-network-cloudflare-tunnel.yml` header comment says "2 replicas". Pick one and align. Default to 2 (HA against pod restart) if it doesn't conflict with the tunnel's Cloudflare-side connection accounting.
- [ ] **3.2** Placeholder-detection bug in `820-deploy` (around line 65-68): compares token to literal `"your-cloudflare-tunnel-token"`. Template ships `""`. Empty token isn't caught. Fix the check to detect both empty and the literal placeholder.
- [ ] **3.3** Verify `cloudflare.env.template` ships the right keys for what 820-deploy + 822-verify actually read. (Probably already correct: `CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_TUNNEL_TOKEN`. Confirm against playbook reads.)

### Phase 4 — Verification on rancher-desktop with `*.skryter.no`

- [ ] **4.1** Tester provides the Cloudflare tunnel token for `*.skryter.no` (pre-configured tunnel in their dashboard pointing at the local rancher-desktop cluster).
- [ ] **4.2** Run `uis network init cloudflare` — wizard prompts for token, writes env file.
- [ ] **4.3** Run `uis network up cloudflare` — token applied to `urbalurba-secrets`, manifest applied, pod rolls out, smoke test passes.
- [ ] **4.4** Deploy a test service (`uis deploy whoami` or `uis deploy nginx`) — verify it gets a Traefik IngressRoute.
- [ ] **4.5** Tester runs `curl https://<service>.skryter.no` from a public network (mobile data, not the same LAN) — should reach the local cluster via the tunnel.
- [ ] **4.6** Verify the four banner/status cases for `uis network list`:
  - cloudflare `✓ running` after `up`
  - cloudflare `· configured, not running` after `down`
  - cloudflare `· not initialized` after `rm .uis.secrets/service-keys/cloudflare.env`
  - tailscale stays in its placeholder hint state throughout
- [ ] **4.7** Run `uis network down cloudflare` — pod removed, env file preserved.

### Phase 5 — Docs lift-up

Sidebar move + tree consolidation + Traefik move + hub rewrite + Cloudflare novice page.

- [ ] **5.1** `website/sidebars.ts`: move `Networking` from nested under `Services` to top-level position 4 (right after `Platforms`).
- [ ] **5.2** Move all `website/docs/services/networking/*.md` content into `website/docs/networking/`. Specifically:
  - `services/networking/traefik.md` → `networking/traefik.md` (Q10).
  - `services/networking/cloudflare-tunnel.md` → fold into `networking/cloudflare-setup.md` (rename to `networking/cloudflare.md`) — single Cloudflare page.
  - `services/networking/tailscale-tunnel.md` → fold into `networking/tailscale-setup.md` — single Tailscale page.
  - `services/networking/index.md` → delete (replaced by `networking/index.md`).
- [ ] **5.3** Rewrite `networking/index.md` as **the networking hub**. The existing 411-line file already has substantive architecture material (dual-tunnel comparison, decision tree, how-it-works) — **preserve those sections; refactor around them**. Don't trash existing material:
  - **New lead**: "UIS networking = how external traffic reaches services in your cluster. Two providers: Cloudflare (public domain tunneling, in-cluster pod) and Tailscale (tailnet-only / Funnel, per-service)."
  - **New section**: canonical `uis network list` output with both providers and their states (cloudflare per the new CLI, tailscale per the "CLI port pending" placeholder).
  - **Preserve / lightly refresh**: side-by-side comparison (Cloudflare vs Tailscale vs Traefik-only), decision tree.
  - **New subsection — "How it works"**: mirror of the platforms hub's cluster-targeting subsection. Networking operations target the active platform via `pf_active_platform` / `target_host`. The `cmd_network_*` family flows through the same banner mechanic as `cmd_platform_*`.
  - **Per-provider link table**: cloudflare.md (fully ported, novice walkthrough) + tailscale-setup.md (current docs, "CLI port coming" callout) + traefik.md.
- [ ] **5.4** Write `networking/cloudflare.md` as the **6-command novice walkthrough**, mirror of `platforms/azure-aks.md`. Verification target is rancher-desktop — don't reference other platforms.
  1. Pre-conditions (Cloudflare account, tunnel-ready domain, tunnel token from dashboard).
  2. `uis network init cloudflare`.
  3. `uis network up cloudflare`.
  4. Verify with a deploy + curl (`curl https://<svc>.<domain>` from a public network).
  5. `uis network status cloudflare` interlude.
  6. `uis network down cloudflare`.
  - Embed the tester's Phase 6 verification output (Phase 4 above + Phase 6 round) verbatim.
  - Sanitize real identifiers (no real subscription IDs, real domain names other than `skryter.no` which the user explicitly OK'd as the example, no real tokens). Follow the same pattern as PR #167 (sanitized AKS identifiers).
- [ ] **5.5** Update `networking/tailscale-setup.md` (and merged `tailscale-tunnel.md` content) — keep current docs but add a "Coming soon" callout that `uis network up tailscale` is on the roadmap, today still use `uis tailscale expose/unexpose/verify`. Link to the future cleanup plan.
- [ ] **5.6** Update `reference/uis-cli-reference.md` — add `Network Management` section with the six subcommands. Match the `Platform Management` shape.
- [ ] **5.7** Cross-ref hygiene: anything pointing at `services/networking/*` follows the move. Anything pointing at the old `uis deploy cloudflare-tunnel` invocation gets updated to `uis network up cloudflare`.
- [ ] **5.8** Local `cd website && npm run build` — must succeed; no new broken links.

### Phase 6 — Tester verification round

- [ ] **6.1** Archive current `talk.md` to `talk50.md` (the docs review round). Write fresh `talk.md` for the Cloudflare-port verification round.
- [ ] **6.2** Brief covers: pull `:latest` once built, `uis network list` cold state, `uis network init cloudflare` with skryter.no token, `uis network up cloudflare`, deploy a service + smoke `https://<svc>.skryter.no` from mobile data, `uis network status cloudflare` panel, `uis network down cloudflare`, post-down `uis network list` cosmetic.
- [ ] **6.3** Capture verbose output for the docs (mirror the talk49 approach — full `up` output, banner first lines, etc. — for Phase 5.4's novice walkthrough).

### Phase 7 — Tailscale follow-up plan stub

- [ ] **7.1** Create `website/docs/ai-developer/plans/backlog/INVESTIGATE-tailscale-architecture-cleanup.md` with:
  - The 802/805 operator collision finding (from this round's INVESTIGATE).
  - The 5-vars-from-template-but-code-reads-different-ones secret-naming finding.
  - Goal: solve both before porting Tailscale to `uis network <verb> tailscale`.
  - Status: "Backlog (do after Cloudflare port + docs lift-up ships)".

This is just a stub so the work is visible; the actual investigation doesn't need to happen this round.

---

## Acceptance criteria

The PR is ready to merge when:

1. `uis help` shows `Network:` block with all six subcommands.
2. `uis network list` returns the right table with cloudflare + tailscale rows.
3. Cold-start novice flow runs end-to-end on rancher-desktop with skryter.no:
   `uis network init cloudflare` → `uis network up cloudflare` → deploy service → `curl https://service.skryter.no` works from public network.
4. `services.json` no longer has `cloudflare-tunnel`. `uis deploy cloudflare-tunnel` errors with redirect hint.
5. Replica mismatch + placeholder bug fixed.
6. Sidebar shows `Networking` at position 4. `services/networking/` is gone (content moved). Traefik lives at `networking/traefik.md`.
7. `networking/index.md` is the platform-style hub, `networking/cloudflare.md` is the platform-style novice walkthrough.
8. `reference/uis-cli-reference.md` has `Network Management` section.
9. Local `npm run build` succeeds.
10. INVESTIGATE-tailscale-architecture-cleanup.md stub exists in backlog.

---

## Estimated effort

| Phase | Effort | Notes |
|---|---|---|
| 1 (cmd_network_*) | ~3 hours | New CLI family, mirror of cmd_platform |
| 2 (remove from services.json) | ~30 min | Delete entries + service-cloudflare-tunnel.sh + test |
| 3 (small bugs) | ~30 min | Two tiny fixes |
| 4 (rancher-desktop verification) | ~30 min | Local cluster, real domain, no Azure cost |
| 5 (docs) | ~2 hours | Sidebar + 3 page moves + hub rewrite + Cloudflare novice page |
| 6 (tester round) | external | Tester runs verification + flags |
| 7 (Tailscale stub) | ~15 min | Just creating the INVESTIGATE stub |

Roughly 6-7 hours of work end-to-end excluding tester time.

---

## Suggested next step

User says "execute" → I start at Phase 1. If you want to split — e.g. ship Phases 1-4 as a code PR, then 5 as a docs PR — say so.
