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

## What to find out

- [ ] 1.1 Whether this is GitHub-side flakiness or something about how the merge is made
- [ ] 1.2 Whether `gh pr merge --squash --delete-branch` is implicated — deleting the head branch in the same operation is the only unusual part, though `3087f4a` did it too and did trigger
- [ ] 1.3 Whether Actions concurrency or queueing suppresses the run (the build workflow serialises on a `concurrency` group)

## The fix that does not need the cause

🔵 **Never treat a merge as a release.** After merging, confirm a build ran *for that exact SHA*, dispatch it if not, and verify the published digest before telling anyone a version exists. That is already the practice; it should be written into the release steps rather than living in one maintainer's habits.

- [ ] 2.1 Write the post-merge check into the release documentation
- [ ] 2.2 🔴 Consider making it refuse rather than remind — a script that compares `version.txt` on `main` against the tags in the registry and reports any version that was merged but never published
