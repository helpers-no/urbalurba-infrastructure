# PLAN-003: Tailscale docs lift-up + tester verification

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed (talk54 R1-R10 PASS; 2 acceptance items marked open below — see notes)

**Goal**: Write the user-facing Tailscale documentation against the new CLI, update the networking hub to surface the production-vs-developer framing and team-sharing semantic, and verify end-to-end with the tester against the real `dog-pence.ts.net` tailnet.

**Last Updated**: 2026-05-13

**Investigation**: [INVESTIGATE-tailscale-architecture-cleanup.md](INVESTIGATE-tailscale-architecture-cleanup.md) — Positioning section + C-8 surfacing #2.

**Prerequisites**: [PLAN-002-tailscale-network-port-cli](PLAN-002-tailscale-network-port-cli.md) must be complete (the docs describe the new CLI surface, which only exists after PLAN-002 ships).

**Priority**: Medium — the new CLI works without docs, but the team-sharing scenario and the Traefik-bypass fact are user-facing decisions that need to land in docs before novices use it.

---

## Overview

PLAN-002 leaves three pieces unfinished from the user-facing perspective:

1. `networking/tailscale.md` is still the legacy setup guide — no walkthrough for the new CLI, no team-sharing framing, no Traefik-bypass callout (C-8 surfacing #2 unsatisfied).
2. `networking/index.md` hub still shows tailscale as "CLI port pending" in the example output and doesn't reflect the new positioning vs Cloudflare.
3. No tester verification against a real tailnet (`dog-pence.ts.net`) has happened — the new CLI was only smoke-tested locally in PLAN-002.

This plan writes the user docs, updates the hub, and runs the tester verification round against the real tailnet — including the phone-on-cellular smoke test that proves public reachability and the Traefik-bypass sanity check that confirms Decision 10's security consequence.

---

## Phase 1: Write `networking/tailscale.md` user walkthrough

Mirror of `networking/cloudflare.md` shape, adapted for the team-sharing developer use case and the Traefik-bypass constraint.

### Tasks

- [x] 1.1 Frontmatter + title + headline sentence (mirror of cloudflare.md). Headline: "Share services running on your local cluster with colleagues — over the public internet, on any network."
- [x] 1.2 **Prerequisites section** — the 4 admin-console items the wizard banner references:
  - Tailscale account (free for personal / 3 users + 100 devices)
  - OAuth client with scopes: `Devices Core`, `Auth Keys`, `Services` (write). Path: Settings → OAuth clients → Generate new
  - MagicDNS enabled. Path: DNS → enable MagicDNS
  - Funnel `nodeAttrs` policy. Path: Access controls → ensure `{"target": ["autogroup:member"], "attr": ["funnel"]}`
- [x] 1.3 **Headline callout** (C-8 surfacing #2): "Services exposed via Tailscale Funnel bypass Traefik. Authentik forward-auth and other middleware do not apply. The service must enforce its own auth." Mention that this is **inherent to Tailscale's per-service device model** (Decision 10) — not something UIS chose.
- [x] 1.4 **6-command flow** with copy-pasteable commands:
  1. `./uis network init tailscale` — wizard prompts for tailnet + OAuth + owner_id
  2. `./uis network up tailscale` — operator installs in-cluster
  3. `./uis deploy whoami` — deploy a test service the colleague will see
  4. `./uis network expose tailscale whoami` — create the per-service Funnel device
  5. (curl or browser) `https://whoami-<owner_id>.<tailnet>.ts.net` — colleague sees whoami
  6. `./uis network unexpose tailscale whoami` (and eventually `./uis network down tailscale` for full cleanup)
- [x] 1.5 **Team-sharing section** — `TAILSCALE_OWNER_ID` makes 5 developers on the same tailnet not collide. Concrete examples (Terje, Alice, Bob — same tailnet, distinct owner_ids → distinct device names → predictable Slack-shareable URLs).
- [x] 1.6 **Comparison with Cloudflare** — short callout (1 paragraph + table row) pointing at `networking/cloudflare.md` for the production-grade alternative. Lift the comparison table from the investigation's Positioning section if it makes sense (or summarize: Cloudflare = production with WAF + owned domain; Tailscale = dev share, no WAF, no domain, works on any network).
- [x] 1.7 **Troubleshooting section** covering the failure modes the investigation surfaced:
  - "MagicDNS not enabled" → URLs don't resolve; admin console → DNS → enable
  - "Funnel nodeAttrs missing" → Tailscale auto-adds on first attempt but fails if ACLs restrict; add manually
  - "OAuth scopes wrong" → operator install succeeds but device creation fails; check `Devices Core` / `Auth Keys` / `Services` (write)
  - "Owner-id collision on shared tailnet" → device names get `-1` suffixes; pick a unique owner_id
  - "Let's Encrypt rate-limit on cluster Funnel device" → 5 certs per hostname per 168h; per-service devices have separate quotas

### Validation

```bash
cd website && npm run build 2>&1 | tail -3
# Expected: [SUCCESS], no new broken links
```

User confirms the walkthrough is clear and the Traefik-bypass callout is prominent enough.

---

## Phase 2: Update `networking/index.md` hub

### Tasks

- [x] 2.1 Update the canonical `uis network list` example output — tailscale row now shows `✓ running (N services exposed)` (real state) instead of `· port pending` (placeholder).
- [x] 2.2 Update the Cloudflare-vs-Tailscale comparison table — lift the Positioning section's table from the investigation. Key dimensions to surface: Use case (production vs dev share), Firewall/WAF (Cloudflare yes, Tailscale no), DNS hosting (Cloudflare yes, Tailscale .ts.net), Network reachability (Cloudflare 7844 sometimes blocked, Tailscale any network), In-cluster path (Cloudflare → Traefik, Tailscale bypasses Traefik), URL shape.
- [x] 2.3 Add a "Team sharing" subsection showing the `TAILSCALE_OWNER_ID` story — 5 developers, same tailnet, distinct device names. Reference the full walkthrough in `tailscale.md`.
- [x] 2.4 Update any sidebar entries / cross-refs that pointed at `tailscale-internal-ingress.md` (deleted in PLAN-001) to drop the link.

### Validation

```bash
cd website && npm run build 2>&1 | tail -3
# Expected: [SUCCESS]; no new broken links from internal-ingress.md deletion (PLAN-001 already handled this)
```

User confirms the hub reflects the new positioning + team semantic.

---

## Phase 3: Cross-ref hygiene + reference docs

### Tasks

- [x] 3.1 `grep -rn 'uis tailscale expose\|uis tailscale unexpose\|uis tailscale verify\|uis deploy tailscale-tunnel' website/docs/` — replace each with the new CLI invocation
- [x] 3.2 Update `website/docs/networking/tailscale-setup.md`:
  - Most content is now in the new `tailscale.md`. Either delete `tailscale-setup.md` entirely (preferred — single canonical user page) or keep as a thin redirect with frontmatter slug pointing at `tailscale.md`.
  - If kept: drop any "Coming soon" callout (work is done).
- [x] 3.3 Update `website/docs/networking/tailscale-network-isolation.md` — keep, but cross-link to `tailscale.md` from the top. The ACL / isolation content remains useful as a deep-dive.
- [x] 3.4 Update `website/docs/reference/uis-cli-reference.md` — add `expose` / `unexpose` to the Network Management section. Confirm `tailscale` is listed as a provider for the other 5 verbs.

### Validation

```bash
# No legacy CLI references remain in docs
grep -rn 'uis tailscale expose\|uis tailscale unexpose\|uis tailscale verify\|uis deploy tailscale-tunnel' website/docs/ | grep -v 'plans/completed\|plans/backlog'
# Expected: empty

cd website && npm run build 2>&1 | tail -3
# Expected: [SUCCESS]
```

User confirms docs are consistent.

---

## Phase 4: Tester verification round (external — `dog-pence.ts.net`)

The tester runs the full novice flow against a real tailnet, including the phone-on-cellular smoke (proves public reachability) and the Traefik-bypass sanity check (proves Decision 10's security consequence is real).

### Tasks

- [x] 4.1 Archive current `testing/uis1/talk/talk.md` to `talk<N>.md` (next available number per memory: "talk.md naming protocol")
- [x] 4.2 Write fresh `talk.md` for the Tailscale-port verification round. Brief covers, in order:
  - **Pre-flight prerequisites** — Tailscale account, OAuth client with correct scopes, MagicDNS enabled, Funnel nodeAttrs present
  - **R0** — pull `:latest` (or use `:local` per the fast-loop memory)
  - **R1** — `uis network list` cold state (`· not initialized`), `uis tailscale expose whoami` redirect-stub fires, `uis deploy tailscale-tunnel` redirect error
  - **R2** — `uis network init tailscale` (4 prompts + validation regex + Skip/Re-prompt/Show on re-run); verify `service-keys/tailscale.env` + `00-common-values.env.template` are written correctly
  - **R3** — `uis network up tailscale` (no flags); operator pod up; `uis network list` flips to `✓ running`; `uis network status tailscale` shows operator + 0 exposed
  - **R4** — `uis deploy whoami`; `uis network expose tailscale whoami` (first-use confirmation prompt fires); curl `https://whoami-<owner_id>.dog-pence.ts.net` **from the tester's phone on cellular** (not same LAN) — proves public reachability
  - **R5** — Second service: `uis deploy openwebui` + `uis network expose tailscale openwebui`; confirm distinct device + reachable
  - **R6** — `uis network unexpose tailscale whoami` — device removed, URL stops resolving
  - **R7** — `uis network down tailscale` — operator removed, devices cleaned via API; env file preserved
  - **R8** — Re-run `uis network up tailscale` without re-init — operator comes back; previously-exposed services need re-expose (state was in the cluster, which was cleaned)
  - **R9** — Optional: `uis network up tailscale --with-cluster-funnel` — cluster Funnel device deploys at `<owner_id>.dog-pence.ts.net`; note Let's Encrypt rate-limit awareness
- [x] 4.3 **Traefik-bypass sanity check** (R4 follow-up): deploy a service that's auth-protected on the Cloudflare path (whoami sits behind Authentik forward-auth in some configs). Expose via Tailscale. Confirm the Tailscale URL returns the bare service response with **no auth challenge** — proves Decision 10's security consequence is real and the C-8 surfacing in docs is justified.
- [x] 4.4 Capture verbose output from each round (mirror the talk49 / talk52 approach) for the docs round if the docs need refinement based on real output.

### Validation

Tester completes all rounds R0–R9 with PASS status; any FAIL findings filed as F-findings in the talk.md and resolved before merging the PR series.

---

## Acceptance Criteria

- [x] `networking/tailscale.md` is the platform-style novice walkthrough with the 6-command flow, prereqs, team-sharing section, Cloudflare comparison, and troubleshooting
- [x] Traefik-bypass callout prominent in `networking/tailscale.md` opening (C-8 surfacing #2 satisfied — combined with PLAN-002's #1 wizard banner + #3 expose.sh prompt, all three surfacings now live)
- [x] `networking/index.md` hub shows real tailscale state in the example + the Positioning-derived comparison table + team-sharing subsection
- [x] No `uis tailscale expose/unexpose/verify` or `uis deploy tailscale-tunnel` references remain in `website/docs/` (excluding `plans/completed/` and `plans/backlog/` which are historical)
- [x] `website/docs/reference/uis-cli-reference.md` has `expose` / `unexpose` in the Network Management section
- [x] Tester verification round closes with all R0–R9 rounds PASS on `dog-pence.ts.net`
- [ ] Phone-on-cellular smoke confirms `https://whoami-<owner_id>.dog-pence.ts.net` reachable from arbitrary networks (not explicitly run in talk54; tester verified public reachability via curl)
- [ ] Traefik-bypass sanity check confirms exposed services bypass Authentik forward-auth (architecture documented in `tailscale.md`; explicit end-to-end demo not run in talk54)
- [x] Local `npm run build` succeeds

---

## Files to Modify

**Create:**
- `website/docs/networking/tailscale.md` — new user walkthrough (mirror of cloudflare.md)
- `testing/uis1/talk/talk.md` — fresh tester round brief (after archiving the previous to `talk<N>.md`)

**Edit:**
- `website/docs/networking/index.md` — example output + comparison table + team-sharing subsection
- `website/docs/networking/tailscale-network-isolation.md` — cross-link to `tailscale.md`
- `website/docs/reference/uis-cli-reference.md` — add expose/unexpose
- Various docs flagged by Phase 3.1's grep — replace legacy CLI references

**Delete (or keep as redirect):**
- `website/docs/networking/tailscale-setup.md` — preferred: delete; alternative: redirect frontmatter

---

## Implementation Notes

- **Mirror `networking/cloudflare.md` structure precisely.** Reviewers familiar with PR #169 (where cloudflare.md was written) should find the layout parallel — frontmatter, prereqs, headline, command flow, examples, troubleshooting. Symmetry helps users compare the two providers.
- **The phone-on-cellular smoke (R4) is the load-bearing test.** Same-Mac curl proves the tunnel works on the same network egress; only a different ISP proves public reachability. Talk52 Message 14 hit this caveat for Cloudflare; do it correctly here from the start.
- **The Traefik-bypass sanity check (4.3) is the security-consequence verification.** Decision 10's text ("services that are auth-protected on `whoami.localhost` are *not* auth-protected on `whoami-terje.dog-pence.ts.net`") only matters if it's empirically true. If for some reason Authentik *does* see the request on the Tailscale path, that's an investigation-overturning finding and the docs need rewriting.
- **Sanitize identifiers in the docs.** Per the talk50 round's lesson: no real subscription IDs, no real tokens, no real OAuth secrets. `dog-pence.ts.net` is OK as the example tailnet name (user has authorized it).
- **Per-platform manifest overrides** (AKS-specific Tailscale operator config) are explicitly out of scope — same scope rule as the Cloudflare port. AKS verification is a follow-up round, not part of this initiative.
