# Bump the GitHub Actions to v5 before the Node 20 runtime deprecation turns fatal

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Completed

**Goal**: Every `actions/*` step in this repository runs on a supported runtime, so the Node 20
deprecation cannot take all four workflows down at once.

**Last Updated**: 2026-08-30 (closed)

**Priority**: High — and it is the only item in the current queue with a clock somebody else
controls. The version-drift investigation and image vulnerability scanning both wait on nobody.

## Problem Summary

Every workflow run currently emits:

```
Node.js 20 is deprecated ... actions/checkout@v4, actions/setup-node@v4 ...
forced to run on Node.js 24
```

GitHub is already overriding the runtime. When the override becomes an error rather than a warning,
**all four workflows fail at once** — docs deploy, container build, doc generation and the test
suite — because they share the same pinned major versions.

Surveyed 2026-08-30:

| Pin | Count | Where |
|---|---|---|
| `actions/checkout@v4` | 8 | all four workflows |
| `actions/setup-node@v4` | 2 | `docs.yml`, `generate-uis-docs.yml` |
| `actions/upload-pages-artifact@v3` | 2 | `docs.yml`, `generate-uis-docs.yml` |
| `actions/deploy-pages@v4` | 2 | `docs.yml`, `generate-uis-docs.yml` |
| `docker/*` (5) and `helm/kind-action@v1` | 6 | `build-uis-container.yml`, `test-uis.yml` |

The change is mechanical. The risk is not: a bad bump breaks **every** CI path simultaneously, and
the failure would land on `main` of a public repository.

## Phases with Tasks

## Phase 1: Bump the first-party actions

### Tasks

- [x] 1.1 `actions/checkout@v4` → `@v5` (8 sites)
- [x] 1.2 `actions/setup-node@v4` → `@v5` (2 sites)
- [x] 1.3 `actions/upload-pages-artifact@v3` → the current major (2 sites)
- [x] 1.4 `actions/deploy-pages@v4` → the current major (2 sites)
- [x] 1.5 Confirm each target major actually exists and read its breaking-change notes rather than
      assuming `vN+1` is a drop-in

### Validation

All four workflow files parse as valid YAML; no `actions/*@v4` or `@v3` pin remains.

---

## Phase 2: Third-party actions

### Tasks

- [x] 2.1 Check whether the five `docker/*` actions and `helm/kind-action@v1` run on the same
      deprecated runtime
- [x] 2.2 Bump only those that need it, and record the ones that do not
- [x] 2.3 Do not bump a third-party action merely to be current — each one is a supply-chain
      decision on a public repo

### Validation

Every remaining pin is either on a supported runtime or recorded as deliberately unchanged.

---

## Phase 3: Prove it in CI, not locally

### Tasks

- [x] 3.1 Declare testable; the independent tester runs the workflows
- [x] 3.2 Confirm the deprecation warning is gone from a real run
- [x] 3.3 Confirm the docs deploy still publishes and the container build still pushes

### Validation

**Tester's verdict: 8/8, closed.** Every claim in Phase 3 was the tester's to make and it made them,
reading the pin out of each run's own `head_sha` rather than trusting a timestamp — because a green
run on the wrong commit is indistinguishable from a green run on the right one.

| workflow | run | commit | pin |
|---|---|---|---|
| `test-uis.yml` | `33321843843` | `fcc275f` | v5 |
| `docs.yml` | `33320095741` | `dedf78f` | v5 |
| `build-uis-container.yml` | `33320095746` | `dedf78f` | v5 |
| `generate-uis-docs.yml` | `33321843871` | `fcc275f` | v5 |

All four: **0 deprecation annotations, 0 zero-step successes**, against **1** annotation on the
pre-bump commit. `generate-uis-docs` did not merely survive — its output commit `3b90cc9` produced
`services.json`, `categories.json` and `tools.json` **md5-identical** to pre-bump.

## Acceptance Criteria

- [x] No `actions/*` pin in the repository sits on the Node 20 runtime
- [x] All four workflows parse and run
- [x] The docs site still deploys from `main`
- [x] The container build still publishes to GHCR
- [x] `test-uis.yml` still runs the static and unit suites on a pull request
- [x] The deprecation warning is absent from a real run
- [x] Any third-party action left unchanged is recorded with the reason

## What the investigation changed — the brief was wrong in three ways

**1. The scope is 19 pins, not 14.** All five `docker/*` actions run on `node20` and are affected
exactly as the `actions/*` ones are. The brief named only `actions/*`; leaving the docker ones would
have left `build-uis-container.yml` failing on the same deadline.

**2. `upload-pages-artifact` is a `composite` action** — it has no node runtime of its own, so it
looked exempt. It is not: `v3` runs `actions/upload-artifact@v4`, which **is** `node20`. (So is
`upload-artifact@v5` — only `v7` moved.) `upload-pages-artifact@v5` pins `upload-artifact` v7 by
SHA, so bumping it is what actually closes this one.

**3. "v5" is not the right target for everything, and is not the latest for anything.** Measured
against each action's own `action.yml`:

| Action | was | → | why that target |
|---|---|---|---|
| `actions/checkout` | v4 `node20` | **v5** | v5, v6 and v7 are all `node24`; v5 is the **first sufficient** major |
| `actions/setup-node` | v4 `node20` | **v5** | same; latest is v7 |
| `actions/upload-pages-artifact` | v3 composite→`node20` | **v5** | see above |
| `actions/deploy-pages` | v4 `node20` | **v5** | v5 is both first-sufficient and latest |
| `docker/setup-qemu-action` | v3 `node20` | **v4** | latest major, `node24` |
| `docker/setup-buildx-action` | v3 `node20` | **v4** | latest major, `node24` |
| `docker/login-action` | v3 `node20` | **v4** | latest major, `node24` |
| `docker/metadata-action` | v5 `node20` | **v6** | latest major, `node24` |
| `docker/build-push-action` | v5 `node20` | **v7** | latest major, `node24` |
| `helm/kind-action` | v1 `node24` | **unchanged** | already supported; bumping it would be change for its own sake |

**Deliberate: `actions/checkout` goes to v5, not the latest v7.** The deadline is the runtime, and
v5 clears it. Two extra majors of breaking-change surface buys nothing against *this* deadline and
risks the failure mode that matters — a bad bump takes all four workflows down at once on a public
repo. Moving further later is a separate decision with nothing forcing it, and it is recorded in
`completed/` rather than left as an unspoken assumption.

⚠️ Every runtime above was read from each action's `action.yml` at the pinned tag, twice — once to
choose the target and once after the edit. None of it is inferred from version numbers.

## Implementation Notes

⚠️ **The rollback is `git revert`, and it is complete** — these are workflow files only. Nothing is
deployed by changing them; the next run picks up whatever is on `main`.

⚠️ **`upload-pages-artifact` and `deploy-pages` are a matched pair.** They are used together in two
workflows; bumping one and not the other is the likely way to break the docs deploy.

⚠️ `docs.yml` also reads `node-version-file: website/.nvmrc`. That is the *project's* node version
and is unrelated to the action runtime — do not "fix" it while here.

## Files to Modify

- `.github/workflows/docs.yml`
- `.github/workflows/build-uis-container.yml`
- `.github/workflows/generate-uis-docs.yml`
- `.github/workflows/test-uis.yml`

## What closing this actually took, beyond the bump

**The pins were the easy part.** Three things made it a real piece of work:

1. **The brief was wrong in three ways**, and only reading each `action.yml` at its pinned tag found
   it: 19 pins not 14, `upload-pages-artifact` looked exempt but is not, and "v5" is neither correct
   for everything nor the latest for anything.
2. **`version.txt` had to move.** The bump republished the image with a moved digest and an unchanged
   version, so `./uis pull` could not see the release at all. That was a defect in the change, and it
   was nearly filed as a caveat for the tester instead — see
   [the version-drift investigation](../backlog/INVESTIGATE-system-launcher-image-version-drift.md).
3. **Two workflows could not notice their own change.** `generate-uis-docs.yml` and `test-uis.yml`
   were missing from their own `paths:` filters, so their bumped pins merged and never ran. Fixing
   the first self-triggered the workflow, which is the fix demonstrating itself. Filed as a class in
   [the paths-filter investigation](../backlog/INVESTIGATE-system-workflow-paths-filter-drift.md)
   after the audit found the fourth instance.

**Every one of those was found by measurement, and three of the four instances of (3) were found by
the tester rather than by an author.** That is the pattern the class investigation exists to break.
