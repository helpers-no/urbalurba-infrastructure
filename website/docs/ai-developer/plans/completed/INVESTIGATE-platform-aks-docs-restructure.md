---
title: INVESTIGATE — Multi-platform docs restructure
sidebar_label: INVESTIGATE — Multi-platform docs
---

# INVESTIGATE — Multi-platform docs restructure

**Status:** Completed — produced [PLAN-multi-platform-docs-restructure](../completed/PLAN-multi-platform-docs-restructure.md) (now in completed/; deliverables shipped piecemeal across multiple PRs)

**Decisions** (2026-05-12, all leans accepted):
- **Q1** = **A** — promote Platforms to ~3rd in the sidebar, right after Getting Started.
- **Q2** = **A** — symmetric per-platform template across all platform pages.
- **Q3** = **A** — add a Platform section to `reference/uis-cli-reference.md` (small touch).
- **Q4** = **A** — novice walkthrough is the body of `platforms/azure-aks.md`.
- **Q5** = **A** — "Cluster targeting" as a subsection of `platforms/index.md`.
- **Q6** = **B** — full rewrite of `platforms/index.md` as the platform hub.
- **Q7** = **A** — `up` → `deploy` bridge lives inline in the novice walkthrough.
- **Q8** = **C** — move INVESTIGATE + PLAN to `completed/` in the docs PR.
- **Q9** = **B** — F17 fix as a small separate PR *before* the docs PR.

(Long-form "Q1 = B as long-term shape" is deferred to a follow-up plan after this round establishes the per-platform template.)

**Goal**: Restructure the user-facing Docusaurus docs (`website/docs/`) so that **UIS-as-a-multi-platform-tool is the headline framing**, not a sub-topic of "Azure AKS". The platform list/use/banner + lockstep-kubeconfig work that just shipped (PRs #160 + #161 + #162 + #163 + #164, verified end-to-end in talk51) is the *user-visible expression* of that framing — `uis platform list` now shows the user has many platforms and can navigate between them in one command. Decide page boundaries before any single page gets written.

**Last Updated**: 2026-05-12

**Depends on**: PR #164 merged + verified (talk51 round closed clean, F14/F15/F16/F18 all green). F17 cosmetic is the only open finding; doesn't gate this work.

**Out of scope**: Implementing the docs (that's the PLAN step). The F17 fix (deferred to a separate PR). Service-specific docs (`services/*`) — those are unaffected by the platform work.

---

## Framing — multi-platform is the headline, not a sub-detail

The single most important framing shift this round must capture: **UIS is a multi-platform deployment tool, not "the Rancher Desktop tool that also has an Azure AKS guide buried under Platforms".**

What changed that makes this an explicit framing question now:

- `uis platform list` is the single command that surfaces **all platforms the user has + their states** in one screen. There's no longer "the local cluster" and "the cloud guide off to the side" — there's one navigable list, with `(active)` indicating which one `uis deploy` will target.
- `uis platform use <name>` is the single command to switch between them. Local k3s, AKS, future GKE/EKS/microk8s — same syntax.
- The banner (`ℹ  Platform: <name> (reachable)`) appears on **every cluster-touching command**, making the active platform a constant visual cue, not a "did I remember to switch context?" gotcha.

The docs should reflect that mental model from the front door, not require a user to dig three levels deep to discover that running on AKS is a first-class option (same goes for the microk8s flavors and any future cloud).

The current docs structure — `Getting Started` (implicitly Rancher Desktop) followed by `Platforms` (one of 7 top-level sections) — frames platforms as one feature among many. The shipped reality says it's closer to a primary axis: *which platform* is a question every user has, every day, and the docs should answer it at the front door.

---

## What just shipped that the docs don't reflect

| Surface | Where it's referenced today |
|---|---|
| `uis platform list` | Nowhere in user docs |
| `uis platform use [<name>]` | Nowhere |
| `uis platform init <provider>` | Nowhere (the legacy guide tells users to copy a template file by hand) |
| `uis platform up <provider>` | Nowhere (legacy guide tells users to run `./platforms/azure-aks/scripts/01-apply.sh` directly) |
| `uis platform status <provider>` | Nowhere |
| `uis platform down <provider>` | Nowhere (legacy guide tells users to run `./platforms/azure-aks/scripts/03-destroy.sh` directly) |
| Banner: `ℹ  Platform: <name> (reachable)` on cluster-touching commands | Nowhere |
| `kubeconf-all` seeded from host kubeconfig + lockstep behavior | One paragraph in `platforms/index.md`, no canonical home |

The published `platforms/azure-aks.md` is a complete walkthrough — well-written, but for the **legacy four-script flow** that the `uis platform <verb>` wrappers now hide. Following it today still works but bypasses the verified novice path.

---

## Current docs map (from survey)

| File | Status |
|---|---|
| `getting-started/overview.md` | ✓ Current — Rancher Desktop only, unaffected |
| `getting-started/installation.md` | ✓ Current — Rancher Desktop install only |
| `getting-started/infrastructure.md` | ✓ Current — high-level concept page |
| `getting-started/architecture.md` | Not yet read; presumed current |
| `getting-started/services.md` | Not yet read; presumed current |
| `platforms/index.md` | ⚠ Partially stale — describes manual `kubectl config use-context` switching; needs `uis platform list / use` |
| `platforms/azure-aks.md` | ⚠ Mostly stale — legacy four-script flow as primary path; supersedes available |
| `platforms/azure-microk8s.md` | Untouched in this work; presumed current for its scope |
| `platforms/rancher-kubernetes.md` | Untouched; presumed current |
| `reference/uis-cli-reference.md` | ⚠ Fully missing — zero `platform` subcommands in the table |
| `reference/tools.md` | ✓ Current — `uis tools install azure-aks` correctly documented |

Plus one un-published asset:
- `testing/uis1/talk/docusaurus-draft-aks-novice-guide.md` — drafted talk46, uses the new `uis platform` flow throughout. Effectively what the published guide should become, after refreshing against talk51's verified outputs.

---

## The shape of the gap, in plain terms

A novice today, following the published docs, would:
1. Run `./uis tools install azure-aks` (✓ correct)
2. Copy a template `.env` file by hand and edit three variables (✗ — `uis platform init azure-aks` now does this with an interactive wizard)
3. Drop into the container shell with `./uis shell`, `cd /mnt/urbalurbadisk`, run `az login --use-device-code`, run `./platforms/azure-aks/scripts/00-bootstrap-state.sh` (✗ — `uis platform up azure-aks` chains these, including the auto-`az login` preflight talk51 surfaced)
4. Run `./platforms/azure-aks/scripts/01-apply.sh` interactively (✗ — chained by `up`)
5. Run `./platforms/azure-aks/scripts/02-post-apply.sh` (✗ — chained by `up`)
6. Deploy services (✓)
7. Tear down with `./platforms/azure-aks/scripts/03-destroy.sh` (✗ — `uis platform down azure-aks`)

Steps 2–5 + 7 all have simpler shipped surfaces the docs haven't been updated to teach. And the discovery commands `uis platform list` / `uis platform use` aren't documented anywhere, even though they're what novices need *first* to see whether their cluster is reachable.

---

## Questions to answer

Decisions get made here before writing PLAN. Each Q is a real branch — none of them are pre-decided.

### Q1 — Top-level sidebar structure: how prominent is "Platforms"?

This is the framing question. Current sidebar order is `index → about → Getting Started → Services → AI Developer → Contributors → Developing → Platforms → Advanced → Reference → Networking`. Platforms is the **8th** category.

Three reshapes that reflect "multi-platform is the headline":

- **A. Promote Platforms to ~3rd, right after Getting Started.** The user opens the docs, learns the basics, then immediately sees "Platforms" as the next category. AKS, microk8s, rancher-desktop all live there as siblings, with the platform list/use mechanic on the index page. Lowest-touch reshape.
- **B. Make "Platforms" the spine of the docs.** Getting Started becomes "Getting Started with Rancher Desktop" (the always-present local one), and other platforms each get their own top-level "Getting Started with X" page. The platform list/use mechanic becomes a cross-cutting page near the top.
- **C. Split "Local development" and "Cloud platforms" as separate top-level categories.** Local = rancher-desktop (the default). Cloud = AKS, microk8s-on-VM, future GKE/EKS. Each has its own getting-started flow, but they share the platform list/use vocabulary.

Tradeoffs:
- A is minimal-risk, achieves the visibility goal, preserves the existing structure. Users who currently know "Platforms is somewhere" find their bookmarks still work.
- B is the most committed framing — says "platform choice is *the* first decision". Bigger restructure, higher writing cost, but the strongest answer to "is multi-platform the headline?".
- C is conceptually clean (local vs. cloud is how users actually think) but adds a new top-level split that the codebase doesn't otherwise have. Risks confusion: where does microk8s-on-multipass go? It's "local" but uses cloud-init tooling.

Current lean: **A** is the minimum viable; **B** is the right long-term shape. I'd recommend A for this round (gets the message out fast) and put B in a follow-up plan once the per-platform pages are healthier. C is probably not right — local/cloud is a soft distinction (microk8s blurs it).

### Q2 — Per-platform page: is the AKS walkthrough still the canonical example?

If Q1's answer makes Platforms prominent, then "the AKS guide" stops being the de-facto "how to use UIS in production" doc and becomes one of N per-platform guides. Two implications:

- **A.** Each per-platform page (`platforms/azure-aks.md`, `platforms/rancher-kubernetes.md`, `platforms/azure-microk8s.md`, etc.) follows the **same template**: what is this platform, prerequisites, novice walkthrough using `uis platform init/up/status/down`, cost/sizing notes, troubleshooting. Symmetric structure across platforms.
- **B.** Keep AKS as the "deep" guide (it's been worked on the most, has the most content) and let other platforms have shorter pages. Accept asymmetry where it reflects content maturity.

Tradeoffs: A is the more durable choice — once the template exists, adding google-gke or aws-eks pages is mechanical. B is less work today but kicks the can.

Current lean: **A** — set the template now while writing the AKS page; other per-platform pages get brought into line in a follow-up. The shared "platform commands" reference (Q3) carries the duplicated material so per-platform pages stay focused.

### Q3 — Where does the `uis platform` command reference live?

(Was Q2 in the prior draft.) The `reference/uis-cli-reference.md` page is the natural home, but it currently has zero `platform` content. Three approaches:

- **A.** Add a "Platform" section to `reference/uis-cli-reference.md` with all six subcommands (list / use / init / up / status / down). Short table-style entries — one-line description + example for each.
- **B.** Create a separate `reference/platform-commands.md` page. More room for canonical example outputs and the state machine; reference page becomes a hub.
- **C.** Generate from `uis help` output via a script. Keeps it in sync forever.

Tradeoffs:
- A is the smallest touch, gets the gap closed today.
- B is better-organized once the reference grows but adds another page upfront. **Also** if Q1's answer is B or C, this becomes more natural — the platform commands deserve a top-level reference page that the platform pages link to.
- C is the long-term win but the `uis help` output is currently a fixed string in `cmd_help()` — not structured. Would need a generator.

Current lean: depends on Q1. If Q1 = A, then **A** here (small touch). If Q1 = B, then **B** here (the elevated framing wants a dedicated reference). C is followup work regardless.

### Q4 — Where does the novice walkthrough live (within whichever structure Q1 picks)?

The talk46-then-refreshed-against-talk51 walkthrough has three reasonable homes within any sidebar shape:

- **A.** As the body of `platforms/azure-aks.md`. The current page becomes the new page. Legacy four-script content gets demoted to a "troubleshooting / direct script access" section near the bottom, or deleted.
- **B.** A new `getting-started/azure-aks-quick-start.md` as the 5-minute novice path. Keep `platforms/azure-aks.md` as the deeper reference (config variables, troubleshooting, cost).
- **C.** Both: short quickstart in getting-started, deep guide in platforms. The quickstart links to the deeper page for anything beyond the happy path.

Tradeoffs:
- A is simplest (one page, one URL).
- B helps if there's a "first cluster" framing that's universal across platforms (each per-platform "quickstart" mirrors the same shape — but then it belongs in `platforms/<name>` per Q2's template, not in `getting-started/`).
- C has maintenance overhead of two pages going out of sync.

Current lean: **A**. The novice path is short (~5 min, 6 commands); gating it behind a "quick start" subpage adds clicks without adding clarity. The deeper "config reference" material can sit below the walkthrough on the same page.

### Q2 — Where does the `uis platform` command reference live?

The `reference/uis-cli-reference.md` page is the natural home, but it currently has zero `platform` content. Three approaches:

- **A.** Add a "Platform" section to `reference/uis-cli-reference.md` with all six subcommands (list / use / init / up / status / down). Short table-style entries — one-line description + example for each.
- **B.** Create a separate `reference/platform-commands.md` page. More room for canonical example outputs and the state machine; reference page becomes a hub.
- **C.** Generate from `uis help` output via a script (similar to how services are auto-listed). Keeps it in sync forever.

Tradeoffs:
- A is the smallest touch, gets the gap closed today.
- B is better-organized once the reference grows but adds another page upfront.
- C is the long-term win but the `uis help` output is currently a fixed string in `cmd_help()` — not structured. Would need a generator.

Current lean: **A** now, **C** later (separate plan, not gating this docs round). B is overkill — the platform commands aren't more important than the others in the reference, just newer.

### Q5 — Does the lockstep + kubeconf-all behavior get its own page?

Two contracts the docs don't currently explain:
- Active platform = `kubectl current-context` in the merged kubeconfig. `uis platform list` / `use` read/write that.
- `cluster-config.sh` (CLUSTER_TYPE / TARGET_HOST) is a cached projection. `pf_lockstep_flip` writes both atomically.

Audience: contributors and advanced users who want to understand why `./uis deploy` knows which cluster to target.

- **A.** Add a "Cluster targeting" subsection to `platforms/index.md`. That page already covers kubeconfig merging at a high level.
- **B.** New page `platforms/cluster-targeting.md` or `advanced/cluster-targeting.md`, linked from `platforms/index.md` and from each per-platform page's "how it works" section.
- **C.** Don't write it as a standalone explainer — let the `uis platform use` command reference entry carry a "what this actually does" paragraph.

Tradeoffs: A keeps the topic discoverable but mixes operator-facing content with contributor-facing content. B is the right structural place once the topic warrants a dedicated page. C avoids creating doc that nobody reads.

Current lean: depends on Q1. If Platforms gets promoted (Q1 = A or B), this content matters more and **B** becomes right. If Q1 stays close to current, **A** is fine.

### Q6 — `platforms/index.md` rewrite scope?

The page currently:
- Explains "what's a platform" conceptually
- Describes manual `kubectl config use-context` switching
- Lists per-platform pages

Two paths:

- **A.** Surgical update — replace the "manual switching" section with `uis platform list` + `uis platform use` examples. Leave everything else.
- **B.** Full rewrite as **the platform hub** — list/use mechanic front-and-center, sample `uis platform list` output, links to per-platform deep pages, includes the cluster-targeting subsection from Q5.

Current lean: **B** — the page is doing double duty (concept explainer + per-platform index), and after the platform-commands ship it should be hub-shaped, not concept-shaped. If Q1's answer is A or B (promote Platforms), this hub is the user's primary landing on multi-platform thinking; can't be surgical-update only.

### Q7 — Do we add a "first commands" or "after `up`" bridge?

Talk51 surfaced that the `up` → `deploy` transition has no documented bridge. The legacy guide jumps from "cluster is up" to "deploy services" without explaining the banner, the active-platform display, or what `kubectl config current-context` will now show.

- **A.** Bridge content lives in the novice walkthrough (Q4's page). User reads through and sees it inline.
- **B.** A small "After your first `uis platform up`" page in getting-started that's linked from both rancher-desktop and azure-aks guides.

Current lean: **A**. The bridge is 3 paragraphs at most; promoting it to a page is over-engineering — unless Q1 = B and the bridge becomes the shared content across per-platform getting-started pages.

### Q8 — Move INVESTIGATE-active-cluster-visibility-ux.md + PLAN-platform-list-use-and-banner.md to `completed/`?

Both are fully implemented and verified in talk51. The PLAN's Phase 7 (tester verification) is what talk51 was.

- **A.** Move both with the docs PR. Update cross-refs.
- **B.** Move separately in a small chore PR after the docs land.
- **C.** Leave in active until the docs land too (treat docs as part of the plan).

Current lean: **C** — the plan isn't "shipped" until users can read about it. Move to `completed/` in the same docs PR or right after.

### Q9 — F17 (cosmetic post-destroy `✗ unreachable`) — fold into the docs PR, or separate?

F17 fix shape (from talk49/50): either clean up the azure-aks context from kubeconf-all in `03-destroy.sh`, or have `status.sh --summary` distinguish "stale context in kubeconfig" from "cluster actually gone".

- **A.** Bundle with the docs PR. One round, one merge, F17 closed alongside the docs that would otherwise have to caveat F17.
- **B.** Separate small PR before the docs PR. Docs then show the polished post-destroy state.
- **C.** Separate small PR after the docs PR. Docs include the talk51-observed `✗ unreachable` output verbatim; if F17 lands later, the docs need a one-line edit.

Current lean: **B** — small enough to do quickly, makes the docs cleaner. But A is fine if you want one PR.

---

## What's NOT being asked

Some things look like decisions but aren't:

- The **content** of each page is not pre-decided here. That's plan-step work.
- Whether to **regenerate the auto-generated provision-host docs** — orthogonal, not affected by this work.
- The future "uis platform list per-cloud cost" / "deep mode" — that's in the PLAN's Phase 7 followups, not this docs round.

---

## Suggested next step

User reviews Q1–Q7, indicates leans for each (or redirects). I write the PLAN against the decisions. PLAN → execute on explicit "execute".
