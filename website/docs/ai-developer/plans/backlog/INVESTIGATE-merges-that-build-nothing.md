---
title: INVESTIGATE — merges to main that produce no build
sidebar_label: INVESTIGATE — merges without builds
---

# Investigate: a merge to `main` that publishes no image, and says nothing

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog — open, cause not established

🔵 Filed 2026-09-29 after it happened twice in one afternoon.

## What is measured

Push-triggered workflow runs per commit on `main`, counted through the API (`?head_sha=<sha>`, filtered to `event=="push"`):

| commit | what it is | push-triggered runs |
|---|---|---|
| `0d04666` | merge of PR #513 (1.6.172) | **0** |
| `3087f4a` | merge of PR #514 (1.6.173) | 4 |
| `0dfb905` | `chore: regenerate UIS documentation` | 0 |
| `dd129fa` | merge of PR #516 (1.6.174) | **0** |

`0dfb905` is expected and not part of this: it was pushed by Actions with `GITHUB_TOKEN`, and GitHub deliberately does not cascade workflow runs from those. **The two merges are not explained.**

All three merges were squash merges with `--delete-branch`, made the same way by the same account, minutes apart. Their paths match the build trigger several times over (`version.txt`, `provision-host/**`). It is not path filtering: **zero runs of *any* workflow** were created for those pushes, including `Test UIS Scripts`.

## 🔴 Why this matters more than a rerun

The failure is silent and it points the wrong way. Nothing reports an error — the PR is green, the merge succeeds, and `latest` simply stays on the **previous** commit. Anyone who then pulls `latest` gets an image that does not contain the fix that was just merged, and the merge says it shipped.

⚠️ That is this repository's dominant defect class — *a command reporting success while the thing it claimed had not happened* — sitting in the release path itself.

**Both releases were published by dispatching the build manually and verifying the digest**, so 1.6.172, 1.6.173 and 1.6.174 are all correct in the registry. The process caught it. **The process catching it is not the same as it not happening.**

## 🔴 Correction, and a worse defect underneath it (2026-09-29, later)

Two more merges, and the picture changed:

| commit | version | push-triggered runs |
|---|---|---|
| `dd129fa` | 1.6.174 | **0**, ever |
| `3982cf1` | 1.6.175 | **0**, ever |
| `d9fdbcf` | 1.6.176 | 4 — **arriving 7 minutes after the merge** |
| `ca2c9ee` | 1.6.177 | 4, promptly |

So it is not always absence. Sometimes the push event is just **very late**, and the original filing could not tell the two apart.

### What that cost

Seeing no runs, I dispatched the build by hand at 19:08:50. The push event then fired at 19:14:26 and built **the same commit again**. Both builds pushed the tag `1.6.176`, and the second won:

```
1.6.176  after the dispatched build  sha256:55bef8a2…
1.6.176  after the push build        sha256:39099afd…
```

🔴 **The same version tag served two different images**, and I had already told a tester the first digest. Whoever pulled in that window has different bytes from whoever pulls now, from one commit.

⚠️ **The build is not reproducible** — same source, different digest — which is ordinary for an unpinned image build, and is exactly why a tag cannot be treated as an identity. `latest` and `1.6.176` are pointers, and a second build moves them.

🔵 **Docs regeneration is not a cause.** `93cbf86` (`chore: regenerate UIS documentation`) carries `version.txt` 1.6.174 and triggered no build, because GitHub does not cascade workflows from a `GITHUB_TOKEN` push. That was worth ruling out.

### So there are two defects, not one

1. **A merge that produces no build at all** (`dd129fa`, `3982cf1`), still unexplained.
2. 🔴 **A version tag that can be rebuilt with different content**, which the workaround for (1) actively causes.

- [ ] 1.4 **Refuse to overwrite an existing tag.** The build should fail, not silently re-point, when `<version>` is already in the registry with a different digest. That makes (2) impossible and turns the duplicate build into a loud no-op.
- [ ] 1.5 Before dispatching by hand, wait long enough to be sure — seven minutes is the measured worst case so far — **and check the registry for an existing image of that version first.**

## What to find out

- [ ] 1.1 Whether this is GitHub-side flakiness or something about how the merge is made
- [ ] 1.2 Whether `gh pr merge --squash --delete-branch` is implicated — deleting the head branch in the same operation is the only unusual part, though `3087f4a` did it too and did trigger
- [ ] 1.3 Whether Actions concurrency or queueing suppresses the run (the build workflow serialises on a `concurrency` group)

## The fix that does not need the cause

🔵 **Never treat a merge as a release.** After merging, confirm a build ran *for that exact SHA*, dispatch it if not, and verify the published digest before telling anyone a version exists. That is already the practice; it should be written into the release steps rather than living in one maintainer's habits.

- [ ] 2.1 Write the post-merge check into the release documentation
- [ ] 2.2 🔴 Consider making it refuse rather than remind — a script that compares `version.txt` on `main` against the tags in the registry and reports any version that was merged but never published
