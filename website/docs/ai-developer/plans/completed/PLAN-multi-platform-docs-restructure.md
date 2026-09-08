---
title: PLAN — Multi-platform docs restructure
sidebar_label: PLAN — Multi-platform docs restructure
---

# PLAN — Multi-platform docs restructure

**Status:** Completed (work shipped piecemeal across multiple PRs; Phase 0 tracked separately as [PLAN-platform-aks-destroy-kubeconfig-cleanup](PLAN-platform-aks-destroy-kubeconfig-cleanup.md))

**Spec**: [INVESTIGATE-platform-aks-docs-restructure.md](INVESTIGATE-platform-aks-docs-restructure.md) — all Q1–Q9 decisions locked in.

**Headline framing** (from the investigation): UIS is a **multi-platform tool**, not a Rancher-Desktop-with-an-AKS-side-guide. The docs structure must surface that at the front door, not bury it as the 8th sidebar category.

**Verified prerequisite**: PR #164 (talk51 verification) — `uis platform list/use/init/up/status/down` + banner + lockstep all work end-to-end on the current `:latest`. F14/F15/F16/F18 closed. The tester's verbose output from talk51 R0–R6 is the source-of-truth material for the rewrites.

---

## Close-out retrospective (2026-05-15)

The plan was never executed as a single unified PR (Phase 7's intended shape). Instead the deliverables landed opportunistically across other PRs over the following weeks. State of each phase as of 2026-05-15:

| Phase | State | Evidence |
|---|---|---|
| 0 — Pre-restructure bug fix | **Open** | Tracked separately as [`PLAN-platform-aks-destroy-kubeconfig-cleanup`](PLAN-platform-aks-destroy-kubeconfig-cleanup.md) in backlog/. |
| 1 — Sidebar promotion | ✓ Done | `sidebars.ts` order is now `index → about → Getting Started → Platforms → …`. |
| 2 — `platforms/index.md` hub | ✓ Done | Page opens with the multi-platform framing + canonical `uis platform list` example. |
| 3 — AKS guide rewrite | ✓ Done | `platforms/azure-aks.md` opens with the six-command novice flow built on `uis platform init/up`. |
| 4 — CLI reference Platform section | ✓ Done | `reference/uis-cli-reference.md` has a Platform Management section parallel to Service / Network / Stack / Secrets. |
| 5 — Per-platform-page touch-ups | ✓ Done | `azure-microk8s.md` carries the "not yet migrated" warning callout (5.4); `rancher-kubernetes.md` is consistent with the new mental model. |
| 6 — Plan relocation + retrospective | ✓ Done | `PLAN-platform-list-use-and-banner.md` + `INVESTIGATE-active-cluster-visibility-ux.md` are both in `completed/`. |
| 7 — Unified verification PR | N/A | Never executed as a single PR; the work shipped piecemeal. |
| 8 — Tester round | N/A | talk51 covered the parts that shipped; no dedicated talk for this PLAN. |

The lesson — when work ends up shipping piecemeal anyway, file the plan as completed and let the remaining phases live as their own focused items rather than wait for an "execute" gate that never fires.

---

## Tester output we'll be quoting

Sections from `/testing/uis1/talk/talk.md` UIS-USER1 Message 1 (talk51 round). All reproduced verbatim in the tester report — no need to re-run the full novice path before writing.

| Section | Use in docs |
|---|---|
| R0 `./uis pull` digest + recycle output | "What `./uis pull` looks like" snippet in getting-started |
| R1 `./uis platform list` cold output (with `(active)` annotation + table) | Canonical `platform list` example on `platforms/index.md` AND the CLI reference entry |
| R2 `up` opening banner + Step 1/2/3 + closing "✓ AKS cluster is up" banner (~7 min total elapsed) | Body of the AKS novice walkthrough |
| R2 `kubectl config get-contexts` showing both `azure-aks *` + `rancher-desktop` | "How active platform works" subsection on the hub page |
| R3 deploy banner (`ℹ  Platform: azure-aks (reachable)`) + task 3 msg + closing nginx summary + curl from host | "Deploy to your cluster" subsection + banner doc on the hub page |
| R4 `platform use` round-trip outputs (both directions, four-locations verification) | `platform use` reference entry |
| R5 destroy output + four-locations auto-reset verification | "Tear down" subsection of AKS guide + cluster-targeting subsection |
| R6 final `platform list` showing `(active)` migrated back + F17 `✗ unreachable` cosmetic | `platforms/index.md` "After a destroy" note |

---

## Phases

### Phase 0 — F17 fix (separate PR, lands before docs)

Per Q9 = B. Small fix, makes the docs cleaner.

- [ ] **0.1** Pick fix shape — `03-destroy.sh` deletes the destroyed platform's context from `kubeconf-all` after destroy succeeds (simpler), OR `status.sh --summary` distinguishes "stale context in kubeconfig" from "cluster API actually unreachable" (richer). Lean: the simpler `03-destroy.sh` cleanup — matches the auto-reset symmetry already in the script.
- [ ] **0.2** Implement, build local image, smoke-test: post-destroy `./uis platform list` should show `azure-aks · configured, not running (run 'up' to start)` (not `✗ unreachable`).
- [ ] **0.3** Static lint + commit + PR. Same template as PR #162/#163/#164.
- [ ] **0.4** CI green → merge → build → next `:latest` carries it. (No tester verification needed; the talk51 expected output table tells us what to look for.)

### Phase 1 — Sidebar promotion (Q1 = A)

- [ ] **1.1** Edit `website/sidebars.ts`: move the `Platforms` category from current position (after `Developing`) to position 3, right after `Getting Started` (before `Services`).
- [ ] **1.2** Sanity-check the rendered nav locally with `cd website && npm run build` (per memory: always build before pushing docs PRs since onBrokenLinks=warn doesn't gate CI).

### Phase 2 — Rewrite `platforms/index.md` as the platform hub (Q6 = B)

Audience: anyone landing on the Platforms category. Their first question: "what *are* my platforms and how do I move between them?"

- [ ] **2.1** New page structure:
  - **Lead**: one paragraph — "UIS targets multiple Kubernetes platforms. Rancher Desktop is the always-present local one. Cloud and remote platforms (azure-aks, azure-microk8s, …) are provisioned on demand."
  - **`uis platform list`** — embed the talk51 R1 output. Explain the four states (`running` / `configured, not running` / `not initialized` / `unreachable`).
  - **`uis platform use <name>`** — embed talk51 R4 output (both directions). Explain "switching" doesn't move workloads; it changes which cluster `uis deploy` etc. target.
  - **Per-platform pages** — short table linking to each (azure-aks, azure-microk8s, multipass-microk8s, raspberry-microk8s, rancher-kubernetes).
  - **How it works — cluster targeting** (Q5 = A subsection): the kubeconf-all + cluster-config.sh lockstep mechanic. Brief — ~150 words. Audience: contributors and users debugging "why does my deploy go to the wrong place?"
- [ ] **2.2** Drop the existing "manual `kubectl config use-context` switching" section. Replace with the `uis platform use` story.
- [ ] **2.3** Cross-link to `reference/uis-cli-reference.md` Platform section (built in Phase 4).

### Phase 3 — Rewrite `platforms/azure-aks.md` as the novice walkthrough (Q4 = A)

Audience: someone who's never provisioned AKS through UIS and wants their first cluster up in 7 minutes.

- [ ] **3.1** Replace the current "Quick start" section (the four-script flow) with the `uis platform` flow:
  1. `./uis tools install azure-aks` (azure-cli + opentofu)
  2. `./uis platform init azure-aks` (interactive wizard — talk51 R2's "✓ AKS setup ready" output)
  3. `./uis platform up azure-aks` (talk51 R2's full output — Step 1 bootstrap with auto `az login`, Step 2 tofu apply ~5 min, Step 3 post-apply with lockstep)
  4. Bridge inline (Q7 = A): "after `up`, the banner on every cluster-touching command shows azure-aks; `kubectl config current-context` in the container returns azure-aks too" — short.
  5. `./uis deploy nginx` (talk51 R3 — banner + task 3 + nginx pod + public smoke)
  6. `./uis platform down azure-aks` (talk51 R5)
- [ ] **3.2** Keep the existing "Prerequisites" table, the "What's in this directory tree" section, the cost notes, and the config-variable reference. These are still current.
- [ ] **3.3** Demote the legacy four-script flow to a short "Direct script access (advanced)" section near the bottom — for users who need to debug a failed apply step-by-step. ~100 words, points at `platforms/azure-aks/scripts/`.
- [ ] **3.4** Add a "Docs-worthy observations" note inline where relevant:
  - Auto-`az login` self-healing during bootstrap (talk51 R2 sub-observation)
  - The `[SUCCESS] cluster-config.sh + kubectl context reset to: rancher-desktop` line after destroy (talk51 R5)

### Phase 4 — Add Platform section to `reference/uis-cli-reference.md` (Q3 = A)

- [ ] **4.1** New "Platform" section in the CLI reference, before or after the existing top-level Container/Service/Stack sections. One short entry per subcommand:
  - `uis platform list [--offline|--deep]`
  - `uis platform use [<name>] [--offline]`
  - `uis platform init <provider>`
  - `uis platform up <provider>`
  - `uis platform status <provider>`
  - `uis platform down <provider>`
- [ ] **4.2** Each entry: one-line description, syntax, one canonical example (use talk51 outputs). No state-machine deep-dives — those live on the hub page.
- [ ] **4.3** Link every entry to the relevant subsection of `platforms/index.md` for the deeper story.

### Phase 5 — Per-platform page template alignment (Q2 = A, light touch)

Goal: don't rewrite every per-platform page this round; just bring them into a consistent shape so the sidebar feels coherent.

- [ ] **5.1** Read each existing per-platform page (`platforms/azure-microk8s.md`, `platforms/rancher-kubernetes.md`, `platforms/multipass-microk8s.md`, `platforms/raspberry-microk8s.md`).
- [ ] **5.2** For each, ensure the first H1 + lead paragraph follows the AKS template shape (audience, what it is, prerequisites). Don't rewrite the rest unless it conflicts with the new `uis platform` mental model.
- [ ] **5.3** Add a "Using UIS platform commands with this platform" callout to each, pointing back to `platforms/index.md` for the `list/use` story. Brief — 2-3 sentences.
- [ ] **5.4** If a page is *deeply* stale (e.g. tells the user to run direct scripts that no longer exist), add a top-of-page warning + flag in the PR description for follow-up.

### Phase 6 — Move INVESTIGATE + PLAN to `completed/` (Q8 = C, in the docs PR)

- [ ] **6.1** `git mv website/docs/ai-developer/plans/active/PLAN-platform-list-use-and-banner.md completed/`
- [ ] **6.2** `git mv website/docs/ai-developer/plans/backlog/INVESTIGATE-active-cluster-visibility-ux.md completed/`
- [ ] **6.3** Add a brief retrospective note to the moved PLAN (one paragraph at the top): "Shipped PRs #161–164. F14/F15/F16/F18 closed; F17 closed in Phase 0 of the docs-restructure PR. Verified end-to-end in talk51."
- [ ] **6.4** Update cross-references — anything pointing at the old backlog/active paths needs to follow.
- [ ] **6.5** Regenerate the plans index if there's an auto-generated one (check `website/docs/ai-developer/plans/active/index.md` and `backlog/index.md`).

### Phase 7 — Local build + PR

- [ ] **7.1** `cd website && npm run build` — must complete with zero warnings on the touched pages. Onbrokenlinks=warn means CI doesn't gate broken links; we gate them here.
- [ ] **7.2** Visually skim the rendered nav locally (`npm run start`) — Platforms appears at position 3, the hub page renders correctly, the AKS guide flows top-to-bottom as the novice path.
- [ ] **7.3** Commit, push, PR. Title: `docs(platforms): multi-platform restructure — promote platforms in nav, rewrite hub + AKS guide on uis platform <verb>`. Body: summary + reference back to INVESTIGATE + talk51 verification.
- [ ] **7.4** CI green → user reviews → merge.

### Phase 8 — Tester verification (single short round)

Not as load-bearing as the talk48–51 rounds (we're shipping prose, not code). A single round to confirm the docs match shipped reality.

- [ ] **8.1** Archive current `talk.md` → `talk51.md` (per the protocol).
- [ ] **8.2** Write a fresh `talk.md` asking the tester to:
  - Read `platforms/index.md` and `platforms/azure-aks.md` as a fresh novice would
  - Run through the AKS guide top-to-bottom (no AKS up needed — just verify the commands and expected outputs match real `:latest` behavior)
  - Flag anything that reads wrong, missing, or surprising
- [ ] **8.3** Iterate on any findings, ship follow-ups as small PRs.

---

## Out of scope this round (followups)

- **Q1 = B long-term spine reshape** — promotes Platforms beyond a sidebar move (each platform gets its own getting-started flow). Bigger restructure; revisit once the per-platform template proves itself in Phase 5.
- **Q3 = C auto-generated CLI reference** — needs a `uis help` generator that emits structured output. Worthwhile, not blocking.
- **`platforms/index.md` cluster-targeting graduating to its own page** — only if the content grows past ~300 words. Per Q5's tradeoff note.
- **Service-specific docs (`services/*`)** — unaffected by platform work.

---

## Acceptance criteria

The docs PR is ready to merge when:

1. Local `npm run build` is warning-free on touched pages.
2. A novice reading `getting-started/installation.md` → `platforms/index.md` → `platforms/azure-aks.md` can provision their first AKS cluster without touching the legacy four-script flow.
3. `reference/uis-cli-reference.md` has all six `uis platform` subcommands.
4. The `platforms/index.md` hub answers "what platforms do I have, which is active, how do I switch" in the first screen of content.
5. Sidebar shows Platforms at position 3, right after Getting Started.
6. F17 fix (Phase 0) has merged → the docs' post-destroy `platform list` example reads `· configured, not running`, not `✗ unreachable`.
7. INVESTIGATE-active-cluster-visibility-ux.md + PLAN-platform-list-use-and-banner.md are in `completed/`.

---

## Estimated effort

Per phase, rough order of magnitude:

| Phase | Effort | Notes |
|---|---|---|
| 0 (F17 fix) | ~1 hour | Small bash change in `03-destroy.sh`, build/PR/merge cycle |
| 1 (sidebar) | ~10 min | One-line edit + local build verify |
| 2 (`platforms/index.md` rewrite) | ~1.5 hours | Hub framing, embed talk51 outputs, cluster-targeting subsection |
| 3 (`platforms/azure-aks.md` rewrite) | ~2 hours | Most prose, most decisions about what to keep/cut |
| 4 (CLI reference) | ~45 min | Six short entries, mostly mechanical |
| 5 (per-platform template alignment) | ~1 hour | Light-touch — header standardization + "platform commands callout" |
| 6 (move plans to completed) | ~15 min | git mv + cross-ref update + retrospective paragraph |
| 7 (build + PR) | ~30 min | Local build, push, open PR, wait for CI |
| 8 (tester round) | external — tester time |  |

Roughly 1 working day end-to-end excluding tester time and PR review.

---

## Suggested next step

User says "execute" → I start at Phase 0. If you want to split — e.g. ship F17 fix first, then the rest later — say so.
