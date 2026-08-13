# Plan: User-facing tools documentation + cleanup of contributor tools doc

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Completed (concrete first slice of [INVESTIGATE-cli-top-level-doc](../backlog/INVESTIGATE-cli-top-level-doc.md))

**Goal**: Make the tools available inside `uis-provision-host` discoverable from the user-facing parts of the docs (today they're only in `contributors/`), and bring the existing contributor doc into line with reality (currently claims tools are pre-installed, lists `terraform`/`oci`/etc. that aren't actually in the system).

**Last Updated**: 2026-05-08

**Related** (system-design context, *not* a prerequisite):
- [INVESTIGATE-system-provision-host-tools-and-auth.md](../backlog/INVESTIGATE-system-provision-host-tools-and-auth.md) — bigger architecture investigation about how tools persist across rebuilds and how provider auth is wired. Tier 3, still deferred. This plan is scoped narrowly to the documentation gap and does not block on that work.

---

## Problem Summary

Two concrete issues, both observable in the current docs as of 2026-05-08:

**1. `website/docs/contributors/architecture/tools.md` is out of date.** Verified drift against the running system:

| Claim in the doc | Reality |
|---|---|
| *"All tools are pre-installed."* | Wrong — there's an on-demand `./uis tools install` system. |
| `az`, `aws`, `gcloud`, `oci`, `terraform` baked in. | None baked in. Three (`azure-cli`, `aws-cli`, `gcp-cli`) are installable; **OCI** isn't in the system at all; **Terraform** was replaced by **OpenTofu**. |
| `cloudflared` + `tailscale` present. | `provision-host-03-net.sh` is skipped for container builds (`provision-host-provision.sh:22-28`); neither is in the default image. |
| `opentofu` | Missing entirely (shipped 2026-05-08 via PR #145). |
| `./uis tools list` / `./uis tools install` | Not mentioned. |

**2. There's no user-facing tools doc.** The current page lives under `contributors/`, so a user reading the user-facing parts of the website (`getting-started/`, `advanced/`, `reference/`, `services/`) never finds it. A user trying to answer *"how do I install Azure CLI inside the provision-host?"* has no entry point.

The fix is two doc files plus three retargeted links. No code, no auto-generation in this round (kept simple; auto-generation is a separate-PR enhancement if drift becomes a recurring problem).

---

## Phase 1: Create `website/docs/reference/tools.md` (user-facing inventory)

User-facing reference page that lists every tool, distinguishes built-in from installable, and gives the install command. Lives in `reference/` so it's discoverable next to `uis-cli-reference.md`.

### Tasks

- [x] 1.1 Create `website/docs/reference/tools.md` with this structure:
  - Lead paragraph: what `uis-provision-host` is and how to access tools (`docker exec` or `./uis shell` if it exists; reference back to `advanced/provision-host/`).
  - **Built-in tools** section: `kubectl`, `k9s`, `helm`, `ansible`. One-line description each (sourced from `provision-host/uis/lib/tool-installation.sh:103-140`). Note these are always present.
  - **Installable on demand** section: `azure-cli`, `aws-cli`, `gcp-cli`, `opentofu`. For each: ID, full name, one-line description, size, install command (`./uis tools install <id>`), and link to the upstream project. Sourced from `provision-host/uis/tools/install-*.sh` metadata.
  - **How to install** section: `./uis tools list` and `./uis tools install <id>` examples. Note that installs survive container restart but disappear on `docker rm`.
  - **Adding a new tool** pointer to the contributor architecture page (Phase 2 below).

- [x] 1.2 Page renders in production Docusaurus build (`cd website && npm run build` → `[SUCCESS]`); appears in the **Reference** sidebar with no broken links. The build runs as the GHCR `Deploy Documentation` workflow on every main merge, providing the same coverage as a dev-server walkthrough.

### Validation

The page lists exactly the eight tools that `./uis tools list` returns today (4 built-in + 4 installable). Every tool description is verbatim from its `install-*.sh` `TOOL_DESCRIPTION` (or the metadata table for built-ins) — no hand-written prose that can drift independently of the source.

---

## Phase 2: Rewrite `website/docs/contributors/architecture/tools.md` (architecture-only)

Pivot the existing page from "inventory of tools" to "architecture of the tools system." Drop the inventory tables (Phase 1's page now owns those); explain how the on-demand install system works and how to add a new installable tool.

### Tasks

- [x] 2.1 Replace the entire body of `tools.md` with architecture-only content:
  - Built-in vs installable split, with one-line rationale for why the image stays small by default.
  - Discovery mechanism: `provision-host/uis/lib/tool-installation.sh:get_all_tool_ids` scans for `install-*.sh` scripts and reads each `TOOL_ID=` line. No registry edit needed when adding a new installer.
  - Installer script shape: required metadata fields (`TOOL_ID`, `TOOL_NAME`, `TOOL_DESCRIPTION`, `TOOL_CATEGORY`, `TOOL_CHECK_COMMAND`, `TOOL_SIZE`, `TOOL_WEBSITE`) and the two required functions (`do_install`, `do_uninstall`). Reference `install-azure-cli.sh` as the canonical example.
  - How to add a new installable tool — concrete step-list using `install-opentofu.sh` (PR #145) as the most recent example.
  - Link out to `reference/tools.md` (Phase 1) for the user-facing inventory.

- [x] 2.2 Delete the stale "Cloud Provider CLIs" section's claim that things are pre-installed. Remove all references to `oci` and `terraform` (replaced by OpenTofu).

- [x] 2.3 Rewritten page renders in the production Docusaurus build; cross-links to `reference/tools.md` resolve cleanly. Verified by the live deployed site at `uis.sovereignsky.no`.

### Validation

The page no longer asserts anything about pre-installed cloud CLIs. Following the "how to add a new installable tool" steps would actually produce a working installer — i.e. the doc is mechanical, not aspirational.

---

## Phase 3: Update cross-references

Pages that link to or mention the tools system today and need to point to the new user-facing inventory. (Three were planned; two more were discovered during implementation and folded in.)

### Tasks

- [x] 3.1 `website/docs/reference/uis-cli-reference.md:138-139` — turn the `./uis tools list` and `./uis tools install <tool-id>` rows into hyperlinks pointing to `reference/tools.md`.

- [x] 3.2 `website/docs/advanced/provision-host/index.md:40` — currently links to `contributors/architecture/tools.md`. Retarget to `reference/tools.md` (the user-facing page) since this index is in the user-facing nav.

- [x] 3.3 `website/docs/ai-developer/plans/backlog/PLAN-platform-aks-001b-manual-setup.md` Phase 2 — currently directs the operator to `./uis tools install azure-cli && ./uis tools install opentofu` without context. Add a one-line link to `reference/tools.md` so first-time operators can see the broader inventory. **(shipped on `feature/aks-config-cloud-accounts` as commit `0c31993`; lands on main when PR #146 merges)**

- [x] 3.4 `website/docs/advanced/provision-host/rancher.md:47` (discovered during grep audit) — same retarget from contributor page to `reference/tools.md`.

- [x] 3.5 `website/docs/reference/documentation-index.md` (discovered during grep audit) — add a Reference-section row for `reference/tools.md`; relabel the Architecture-section row to "Tools System Architecture" with an architecture-flavoured description.

### Validation

`grep -rn "contributors/architecture/tools.md" website/docs/` returns only hits inside `contributors/architecture/tools.md` itself (self-references) or other contributor-facing pages. No user-facing doc still routes readers to the contributor page.

---

## Acceptance Criteria

- [x] `website/docs/reference/tools.md` exists, lists 8 tools matching `./uis tools list` output verbatim (4 built-in, 4 installable).
- [x] `website/docs/contributors/architecture/tools.md` describes the install-*.sh architecture and "how to add a tool"; no longer asserts anything is pre-installed; no longer mentions `oci` or `terraform`.
- [x] The cross-references are retargeted as in Phase 3 (one task deferred to AKS branch — see 3.3).
- [x] Both pages render in the production Docusaurus build (`npm run build` → `[SUCCESS]`); deployed live at `uis.sovereignsky.no`.
- [x] This plan is in `completed/`.

---

## Files to Modify

- `website/docs/reference/tools.md` (new)
- `website/docs/contributors/architecture/tools.md` (rewrite)
- `website/docs/reference/uis-cli-reference.md` (cross-ref update)
- `website/docs/advanced/provision-host/index.md` (cross-ref update)
- `website/docs/ai-developer/plans/backlog/PLAN-platform-aks-001b-manual-setup.md` (cross-ref update)
- `website/docs/ai-developer/plans/active/PLAN-tools-docs.md` → `completed/` (when done)

---

## Implementation Notes

- **Hand-maintained, not auto-generated.** The doc rebuild is small (8 tools), the auto-generation effort isn't justified at this size. If the inventory grows or drift recurs, revisit by extending `provision-host/uis/manage/uis-docs.sh` to emit this page from `install-*.sh` metadata. Tracked as a future enhancement, not part of this plan.
- **Don't touch the system itself.** [INVESTIGATE-system-provision-host-tools-and-auth.md](../backlog/INVESTIGATE-system-provision-host-tools-and-auth.md) owns the questions about persistence (`enabled-tools.conf`), auth state (`.uis.secrets/cloud-accounts/`), and `target setup` integration. This plan is *only* about documentation; if either page tries to describe behaviour that doesn't yet exist, defer to that investigation rather than describing a future state.
- **Verify against `./uis tools list` output, not against assumptions.** The drift in the current `tools.md` came from describing what *should* be there. The fix is to describe what `./uis tools list` *does* show — generate the listing live in the container at write time, copy verbatim.
