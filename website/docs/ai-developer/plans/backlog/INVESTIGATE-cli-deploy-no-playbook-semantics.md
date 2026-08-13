# Investigate: `./uis deploy <service>` semantics for services without a playbook

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: Decide what `./uis deploy <service>` should do when the target service has `SCRIPT_PLAYBOOK=""` (and `SCRIPT_MANIFEST=""`) — the "metadata-only" case introduced when [`service-postgrest.sh`](https://github.com/helpers-no/urbalurba-infrastructure/blob/main/provision-host/uis/services/integration/service-postgrest.sh) shipped without a playbook (PLAN-001 documentation gate; PLAN-002 will add the playbook).

**Last Updated**: 2026-04-29

**Request origin**: Surfaced by uis-user1 during `talk.md` Round 4 of registry-image validation for PR #130 (postgrest icon-only logo + cross-folder link fixes). Two findings reported; both pre-existing UIS dispatch behavior, not bugs introduced by the postgrest work — but exposed for the first time because postgrest is the first UIS service shipped without a playbook.

**Depends on**: nothing — pure UIS dispatch-layer question. PLAN-002 (postgrest deployment) will eventually give postgrest a playbook, eliminating the *immediate* trigger; but the underlying behavior remains for any future metadata-only service (e.g. consumer-side "documentation-first" plans following PLAN-001's pattern).

---

## What was observed

Running `./uis deploy postgrest` on the freshly-pulled `ghcr.io/helpers-no/uis-provision-host:latest` image (commit `fd7cfa8`):

```
ℹ Applying secrets to Kubernetes cluster...
secret/urbalurba-secrets configured
… [≈20 lines of secret/namespace mutations across 9 namespaces] …
✓ Secrets applied to cluster
ℹ Deploying service: postgrest
ℹ Deploying PostgREST (postgrest)...
ℹ Dependency 'postgresql' is deployed
⚠ Service 'postgrest' has no SCRIPT_PLAYBOOK or SCRIPT_MANIFEST - nothing to deploy
```

Exit code: **0**.

Two distinct issues here.

---

## Finding 1 — Exit code 0 is misleading for scripts

The user invoked `deploy <service>`. The service was *not* deployed. The dispatcher correctly identifies this and emits a warning. But it then exits 0.

**Failure mode**: any caller scripting `./uis deploy <svc>` and checking `$?` (e.g. CI pipelines, the testing protocol's `talk.md` rounds, a downstream `./uis deploy a && ./uis deploy b` chain) interprets warn-then-exit-0 as success. The user's mental model — "deploy verb implies a side effect; if no side effect, that's a failure of intent" — is broken.

**Mitigations callers have today**: parse stderr/stdout for the `⚠` warning string. Brittle.

**Why this hasn't bitten before**: every existing UIS service has a `SCRIPT_PLAYBOOK`. The no-playbook code path was never user-visible until postgrest landed.

**Why this matters for future "documentation-first" plans**: PLAN-001-postgrest-documentation established a useful pattern — ship a service's metadata + docs page *before* the deployment plan, so consumers can review the design against real Docusaurus output. That pattern is broadly useful (Atlas's PLAN-004 uses a similar shape from the consumer side). Each future docs-first plan exposes the same exit-0 ambiguity until its companion deployment plan ships. The window can be days or weeks.

---

## Finding 2 — Pre-flight runs before the playbook-presence check

The dispatcher applies `urbalurba-secrets` across 9 namespaces (`ai`, `argocd`, `jupyterhub`, `unity-catalog`, `openmetadata`, `backstage`, `enonic`, `nextcloud`, `monitoring`, `authentik`) **before** discovering that the requested service has nothing to deploy.

**Failure mode**: a deploy of a no-op service triggers real cluster mutations. Idempotent and cheap in this case (every `secret/urbalurba-secrets configured` line resolves to no actual change since the secret content didn't change), but the *intent* of `deploy <metadata-only-service>` is "do nothing" — and it should achieve nothing.

**Why this matters**: the assumption that the user expects cluster mutations on every deploy is wrong for the metadata-only case. It's also a foot-gun: a contributor who wants to dry-run "what does this service look like in our deploy ordering?" gets unexpected cluster-state changes for free.

**Pre-flight ordering question**: should `Applying secrets…` run for *every* `./uis deploy <svc>`, or only when the dispatcher has confirmed there's actually deploy work to do? The "every time" choice makes sense if every service has a playbook (the original assumption). Once metadata-only services exist, the choice becomes "every time vs only-when-needed."

---

## Considered options

### Option A — Refactor: presence-check first, pre-flight second

Reorder the dispatcher:

1. Look up `SCRIPT_PLAYBOOK` / `SCRIPT_MANIFEST` for the target service.
2. If both empty, emit a clear error message ("service has no playbook; nothing to deploy") and **exit non-zero**.
3. Otherwise, run pre-flight (secrets sync, dependency check) and the playbook.

**Pros**: fixes both findings at once. Scripts can `&&`-chain reliably. No spurious cluster mutations on no-op deploys.

**Cons**: changes existing UIS dispatch behavior; need to verify no other code path relies on the current ordering. Probably small change; risk is low but not zero.

### Option B — Keep ordering, change exit code only

Leave pre-flight where it is. After the no-playbook check, exit non-zero instead of 0.

**Pros**: smaller change; only the exit-code semantics shift.

**Cons**: doesn't address Finding 2. Cluster mutations still happen on no-op deploys.

### Option C — Soft no-op: leave behavior as-is, document it

Treat warn-then-exit-0 + pre-flight-always as the documented contract. Update the contributor docs to make the convention explicit, and make any caller that wants to detect "deployed nothing" parse stdout for `⚠`.

**Pros**: zero code change.

**Cons**: brittle for scripts; misleading user mental model; doesn't scale to future metadata-only services. Effectively a "won't fix."

### Option D — Make metadata-only services explicit at dispatch level

Add a `SCRIPT_METADATA_ONLY="true"` flag (or detect via empty `SCRIPT_PLAYBOOK`+`SCRIPT_MANIFEST`). When set, `./uis deploy <svc>` exits non-zero with a friendlier message ("`postgrest` is metadata-only — see [docs link]; deployment lands in PLAN-002") and skips pre-flight entirely.

**Pros**: cleanest user-facing message; explicit intent; doesn't require reordering pre-flight in general.

**Cons**: adds a new metadata field. Equivalent to Option A in effect (presence-check first), with extra ergonomics.

---

## Recommendation

**Option A** — reorder dispatcher: presence-check first, pre-flight second; exit non-zero when neither field is set. Reasons:

- Fixes both findings in one change.
- Doesn't add a new metadata field (the `SCRIPT_PLAYBOOK=""` test is already the source of truth for "is this deployable").
- Keeps the warning message; just promotes it to error-level and bails out before pre-flight.
- Future metadata-only services (consumer-side `INVESTIGATE-*` → `PLAN-001-docs` pattern) inherit the correct behavior automatically.

Option D's friendlier message is appealing, but the same effect can be achieved in Option A's error text without adding a metadata field — the error can read `Service 'postgrest' has no SCRIPT_PLAYBOOK or SCRIPT_MANIFEST. Either: (a) it is metadata-only by design (see service docs), or (b) the deployment hasn't been wired up yet (check the service's plans/ folder for an open PLAN-*).`

---

## Files likely to change

- `provision-host/uis/manage/uis-cli.sh` — the deploy dispatch entry point
- `provision-host/uis/lib/deploy.sh` (or wherever the playbook-presence check currently lives) — reorder so it runs before pre-flight
- `provision-host/uis/lib/secrets.sh` (if pre-flight lives here) — caller change only; no internal changes
- A test exercising both code paths: `./uis deploy <existing-service>` (full path, exit 0) and `./uis deploy postgrest` (metadata-only path, exit non-zero)

Investigation should also locate the actual current location of pre-flight + presence-check code before scoping the fix; the surface may be smaller (or larger) than described above.

---

## Next Steps

- [ ] **PLAN-uis-deploy-no-playbook-fix.md** — implement Option A. Small scope: re-order the dispatcher, change the exit code, write the regression test. Single PR.

Trigger: when a maintainer has spare cycles, OR when a second metadata-only service ships and the issue resurfaces, whichever comes first. Not blocking PostgREST PLAN-002.

---

## Cross-references

- Surfaced in `/Users/terje.christensen/learn/helpers/testing/uis1/talk/talk.md` (Round 4, 2026-04-29) — uis-user1 reported both findings during PR #130 registry-image validation.
- Affects future "documentation-first" plans following [PLAN-001-postgrest-documentation.md](../completed/PLAN-001-postgrest-documentation.md)'s pattern — every such plan creates a window where the service exists in `./uis list` but has no playbook.
