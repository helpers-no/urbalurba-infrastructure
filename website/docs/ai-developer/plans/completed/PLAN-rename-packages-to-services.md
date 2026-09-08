# PLAN: Rename "Packages" to "Services" in Documentation

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Created**: 2026-03-17
**Status:** Completed (2026-03-17)
**Parent**: [INVESTIGATE: Old System Cleanup & Documentation Gaps](../completed/INVESTIGATE-old-system-cleanup.md)

## Goal

Rename all references from "packages" to "services" in the documentation, CLI metadata, and doc generator — so the docs match the CLI terminology (`./uis deploy <service>`, `services.json`, `service-*.sh`).

---

## Why

The CLI and data model use "services" everywhere. The documentation uses "packages." A user clicking "Services" in the navbar lands on a page that links to "Packages" in the sidebar. This creates confusion about whether these are different concepts. They're the same thing.

---

## Scope

### What changes

| Area | Count | What |
|------|:-----:|------|
| Folder rename | 1 | `website/docs/packages/` → `website/docs/services/` |
| Category JSON files | 11 | `_category_.json` in root + 10 subcategories |
| Service doc pages | ~40 | Move with the folder (no content changes needed) |
| Sidebar config | 1 | `website/sidebars.ts` — ~40 path references |
| Site config | 1 | `website/docusaurus.config.ts` — footer link |
| Homepage | 1 | `website/src/pages/index.tsx` — button link |
| Utilities | 1 | `website/src/utils/paths.ts` |
| Doc generator | 1 | `provision-host/uis/manage/uis-docs-markdown.sh` — 6 path references |
| Service scripts | 30 | `SCRIPT_DOCS` field in every `service-*.sh` |
| services.json | auto | Regenerated from service scripts — `docs` field updates automatically |
| Doc references | ~33 | Files across `website/docs/` that link to `/docs/packages/...` |

### What does NOT change

- Service definitions (`SCRIPT_ID`, `SCRIPT_NAME`, etc.) — only `SCRIPT_DOCS` changes
- Ansible playbooks — no references to docs paths
- The `/services` page (`website/src/pages/services.tsx`) — already uses the right name
- `services.json` structure — only the `docs` field values change

---

## Phases

### Phase 1: Rename folder and update config

1. Rename `website/docs/packages/` → `website/docs/services/`
2. Update root `_category_.json` label from "Packages" to "Services"
3. Update `website/sidebars.ts` — replace all `packages/` with `services/`
4. Update `website/docusaurus.config.ts` — footer link `/docs/packages/ai` → `/docs/services/ai`
5. Update `website/src/pages/index.tsx` — button link
6. Update `website/src/utils/paths.ts` — if it contains package paths

**Validation:** `npm run build` — Docusaurus will catch every broken internal link.

### Phase 2: Update doc generator and service scripts

7. Update `provision-host/uis/manage/uis-docs-markdown.sh` — change output path from `docs/packages/` to `docs/services/` (6 references)
8. Update `SCRIPT_DOCS` in all 30 `service-*.sh` files — `/docs/packages/<cat>/<svc>` → `/docs/services/<cat>/<svc>`
9. Run the doc generator to verify it writes to the new path
10. Run `npm run build` again to verify generated output is consistent

**Validation:** Run `./uis docs generate` (or `bash provision-host/uis/manage/uis-docs-markdown.sh`), then `npm run build`.

### Phase 3: Update internal documentation links

11. Update all ~33 files in `website/docs/` that reference `/docs/packages/...`
    - Most are in `ai-developer/plans/` (completed investigations and plans)
    - Some are in `contributors/guides/` and `contributors/rules/`
12. Run `npm run build` — should produce zero broken link warnings

**Validation:** Clean build with no warnings.

### Phase 4: URL redirects (optional)

13. Evaluate whether to add `@docusaurus/plugin-client-redirects` for `/docs/packages/*` → `/docs/services/*`
    - Only needed if external sites link to the old URLs
    - The site is relatively new — external links are unlikely
    - Skip if not needed, add later if broken links appear in analytics

---

## Validation Checklist

- [x] `npm run build` passes with zero broken links
- [x] `./uis docs generate` writes to `website/docs/services/`, not `packages/`
- [x] Sidebar shows "Services" category with all subcategories
- [x] Footer link works
- [x] Homepage button links to correct path
- [x] `/services` page service cards link to `/docs/services/...`
- [x] No file in the repo contains the string `/docs/packages/` (except completed plan files describing the rename itself)

---

## Risks

- **CI/CD generator writes to old path**: If `generate-uis-docs` workflow runs before the script is updated, it will recreate `docs/packages/`. Mitigation: update the script and service scripts in the same commit/PR.
- **External links break**: The old `/docs/packages/...` URLs will 404. Mitigation: site is new, low risk. Add redirect plugin later if needed.
- **Merge conflicts**: If other work is in progress that touches `sidebars.ts` or service docs. Mitigation: do this rename early, before other doc work.
