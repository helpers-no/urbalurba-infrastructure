# Plan: Epinio build-safety policy — a broken push has no automatic protection

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Completed

**Goal**: Decide, and document, what UIS does about Gate 8's finding — `epinio push --git`
has no built-in protection against a broken build taking down the previously-running
version — before production rollout to tor/frigg/odin depends on it.

**Investigation**: [INVESTIGATE-service-epinio-deploy-path.md](../backlog/INVESTIGATE-service-epinio-deploy-path.md)

**Prerequisites**: None — this does not need a cluster. It reads ops's already-live-verified
finding and decides policy from it.

**Blocks**: `PLAN-service-epinio-003-namespace-and-push.md` (not started) — whatever wraps
`epinio push` as `uis epinio push` must carry this decision forward, not rediscover it.

**Priority**: Medium — one of the four conditions `urb-agents#1911` set before production
rollout (condition 2, `urb-agents#2019`). Not a go/no-go gate on the PoC itself; ops's own
gate list already classified Gate 8 as "a supporting test, not one of the 7 bolded gates."

**GitHub Issue**: `urb-agents#2019` (ops), `urb-agents#1911` (the GO decision this is a
condition of)

**Last Updated**: 2026-10-26

---

## Problem Summary

`urb-agents#1909`'s 18-test gate list included Gate 8, run live against the `-test` cluster
PoC by ops (`urb-agents#1911`, 2026-10-26):

> Gate 8 FAILED — a broken build does not keep the old version live; Epinio's readiness
> gate provides no protection by design. No configuration fix found.

Epinio's own CLI has no rollback or revision-history command (`epinio app` subcommands:
`create, delete, env, exec, export, list, logs, manifest, port-forward, push, restage,
restart, show, update, watch` — nothing that switches back to a previous build). Each
pushed app is its own Helm release; `epinio push` builds a new image and upgrades that
release in one step, with no separate "did the new version come up healthy before the old
one goes away" gate protecting whatever was running before. This is Epinio's own measured
behavior (ops, live, against the real PoC) — not a UIS bug, and not fixable by any UIS-side
configuration.

**The exposure is specific to the buildpack push path, `epinio push --git`.** It does not
apply to the registry-image push path (`epinio push --container-image-url`, Gate 12's
mechanism) at all: that path's build step runs in Forgejo Actions CI, independently of
Epinio, and a broken build there simply never produces an image for the registry to hold or
Epinio to deploy — the failure is caught upstream, before Epinio is ever involved. The same
split already surfaced for an unrelated reason at Gate 16 (Paketo's buildpack builder images
are amd64-only, so `--git` panics on Apple Silicon while `--container-image-url` is
architecture-agnostic) — two independent findings, same fix.

## Decision

**Accept for v1. Do not block production rollout on building Epinio-side rollback
tooling that does not exist upstream.** Mitigate entirely through steering and
documentation, which is buildable now, and bind the future `uis epinio push` wrapper
(`PLAN-service-epinio-003-namespace-and-push.md`) to carry the same policy forward:

1. **The registry-image path (`--container-image-url`) is the recommended default** for any
   team whose app must stay up through a bad push — it is already proven end-to-end (Gate
   12) and the build-failure risk simply does not reach Epinio on that path.
2. **The buildpack path (`--git`) stays available**, documented plainly as having no
   automatic protection: a broken build can take a working app down, and the only recovery
   is pushing a known-good git ref again by hand. This is a real, valid workflow for fast
   local iteration — removing it would cost more than the risk it carries, and Terje's
   original ask (Heroku/Vercel-shaped ergonomics) is specifically this path.
3. **`PLAN-service-epinio-003-namespace-and-push.md` must not design `uis epinio push`
   without this split already decided.** When that PLAN is written, it should decide
   whether the wrapper defaults to the registry path, requires an explicit flag for the
   buildpack path, or simply surfaces this doc's warning at push time — a decision for that
   PLAN, but one that starts from this policy rather than re-discovering Gate 8.

This is not a go/no-go reversal of `urb-agents#1911`'s GO call — ops's own gate list already
treats Gate 8 as a supporting test, and the mitigation above is exactly the kind of
"configuration/steering fix" the gate list's own rule accepts in place of a hard fail.

## Phase 1: Document the policy

### Tasks

- [x] 1.1 Add a "Build safety" section to `website/docs/services/management/epinio.md`
      stating the policy above in developer-facing terms: use
      `--container-image-url` if a bad push must not take the app down; `--git` has no
      safety net and the only recovery is re-pushing a known-good commit.
- [x] 1.2 Record Gate 8's finding and this decision in
      `INVESTIGATE-service-epinio-deploy-path.md`'s open-items list, so neither is
      re-derived from scratch when `PLAN-service-epinio-003-namespace-and-push.md` is
      written.
- [x] 1.3 Renumber the two not-yet-written follow-on PLANs referenced in that
      INVESTIGATE's Next Steps list (`-002-namespace-and-push` → `-003-namespace-and-push`,
      `-003-identity` → `-004-identity`) so this PLAN's number is not reused.

### Validation

`npm run build` in `website/` renders both edited pages without broken links.

## Acceptance Criteria

- [x] The push-safety split (registry path vs. buildpack path) is documented in
      `epinio.md`, in terms a developer pushing an app would act on.
- [x] `INVESTIGATE-service-epinio-deploy-path.md` records Gate 8 and this decision, so a
      later PLAN starts from it.
- [x] No code change — this is a policy decision with no cluster dependency, matching
      ops's own framing that Gate 8 is a supporting test, not a go/no-go gate.

## Implementation Notes

- Epinio CLI command list and the absence of a rollback/revision command verified against
  Epinio's own published docs (`docs.epinio.io`, CLI reference), not assumed.
- This plan deliberately does not attempt to build a safety mechanism UIS does not have a
  proven reference for (e.g., a custom pre-push smoke test, a canary wrapper around `epinio
  push`). `do-not-invent-ground-in-proven-reference` applies: the registry-path mitigation
  is already proven (Gate 12); a bespoke guard would not be.
- Also noticed in passing, not fixed here (separate, unrelated gap): `epinio.md`'s existing
  "Verify" section documents `./uis verify epinio`, but nothing dispatches it — `epinio`
  is not wired into `cmd_verify`, `VERIFY_SERVICES`, or any top-level verb in `uis-cli.sh`,
  and no `*-test-epinio.yml`/`*-verify-epinio.yml` playbook exists to wire up even if it
  were (unlike `070-verify-authentik.yml`, which existed, just undispatched —
  `urb-agents#2013`). Flagged in `INVESTIGATE-service-epinio-deploy-path.md`'s open items
  for whichever PLAN next touches Epinio's CLI surface; not this plan's scope, and not
  something to invent a verify playbook for blind.

## Files to Modify

- `website/docs/services/management/epinio.md`
- `website/docs/ai-developer/plans/backlog/INVESTIGATE-service-epinio-deploy-path.md`
- `website/docs/ai-developer/plans/backlog/1PRIORITY.md`
