# Plan: four dependency alerts on the docs site, and why bumping does not clear them

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Backlog

**Goal**: The repository's open dependency alerts are either cleared or
recorded with a reason, so that "4 open" stops meaning "nobody has looked".

**Found**: 2026-09-10. GitHub reported them on a push; assessed the same hour.

---

## What is actually open

All four are in `website/package-lock.json` — the **documentation site**, not
the product. Nothing here ships in `uis-provision-host`.

| severity | package | vulnerable | first patched |
|---|---|---|---|
| medium ×2 | `qs` | `>= 2.2.5, < 6.16.0` | **6.16.0** |
| high ×2 | `image-size` | `<= 2.0.2` | 🔴 **none** |

## 🔴 The finding that saves the next person an afternoon

`npm audit` proposes fixes for sixteen `@docusaurus/*` packages, several
`isSemVerMajor`. **They are noise.** The whole cascade has one root:

```
@docusaurus/core@3.9.2 -> @docusaurus/mdx-loader@3.9.2 -> image-size@2.0.2
```

and **there is no patched `image-size`** — every version up to and including
the latest is in range. Checked directly: `@docusaurus/mdx-loader@3.10.2`, the
newest release, still declares `image-size: ^2.0.2`.

⚠️ **So upgrading Docusaurus does not clear these alerts.** It churns the
lockfile, risks the docs build, and leaves both `high` rows exactly where they
are. Anyone who runs `npm audit fix --force` here will conclude the opposite
from its output.

## What the exposure actually is

`image-size` runs at **build time**, in CI, over images committed to this
repository. The published site is static HTML and JS; the vulnerable code is
not in it and a visitor cannot reach it. That is a real reduction in risk and
it is **not zero** — a contributor could add a crafted image, and the builder
holds a token.

⚠️ Stating it rather than concluding from it. "Build-time only" is the kind of
mitigation that is true right up until someone adds an untrusted input, and
this plan should not be closed on it alone.

## What needs deciding

1. **`qs` has a real fix.** It is a transitive dep with a patched version, so
   an `overrides` entry pinning `qs` to `>= 6.16.0` clears two rows without
   touching Docusaurus. Cheap; verify the docs build after.
2. **`image-size` cannot be fixed here.** Options: accept and dismiss the
   alerts with the reason recorded; wait for upstream; or pin an override to a
   version that does not exist yet (not an option). Dismissing an alert is a
   decision that should be visible, not a tidy-up.
3. **Does the docs site want Dependabot at all?** It has produced four merged
   PRs today, all trivial, and the one thing it cannot fix is the one thing
   flagged `high`. Worth asking whether the signal is worth the traffic.

## Tasks

- [ ] 1.1 Add the `qs` override, rebuild, confirm two rows clear
- [ ] 1.2 Decide question 2 — 🔴 if dismissing, record the reason **in this
      file**, not only in the GitHub UI where nobody reads it
- [ ] 1.3 Re-check `image-size` when Docusaurus next releases; the fix is
      upstream's to make
- [ ] 1.4 Decide question 3

## Acceptance

- every open alert is either fixed or has a written reason it is not
- ⚠️ the reason is in the repository. An alert dismissed only in GitHub's UI
  is invisible to the next person reading this plan, which is the failure this
  file exists to prevent

## The lesson this plan carries

**`npm audit`'s "fixAvailable" answers a different question than the one you
asked.** It reports whether *some* dependency change makes the advisory stop
matching — not whether the vulnerable package has a patch. Sixteen proposed
upgrades, one unfixable root, and the output reads like the opposite. Another
instance of the shape this repository keeps finding: true about the narrow
thing, read as the broad one.
