# Fix: `./uis undeploy --purge --yes` returns before namespace is fully deleted

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Completed**: 2026-05-03

**Goal**: Make `./uis undeploy gravitee --purge --yes` block until the gravitee namespace is fully terminated, so an immediately-following `./uis deploy gravitee` can re-create namespace resources without hitting `HTTP 403 namespace … is being terminated`.

**Last Updated**: 2026-05-03

**Reported in**: `/Users/terje.christensen/learn/helpers/testing/uis1/talk/talk.md` Round 1.5, Issue A. Reproducer: tester ran `./uis undeploy gravitee --purge --yes && ./uis deploy gravitee` back-to-back; undeploy exited 0 with the namespace still in `Terminating` phase, so deploy's secrets-apply step failed twice with `Error from server (Forbidden): … namespace gravitee … being terminated`. Workaround was a 30s manual wait before retrying deploy.

**Why this matters**: every future gravitee-config experiment round depends on `--purge` producing a true clean slate. Without this fix, every round's baseline is contaminated by either stale state (if we skip purge) or by the manual-wait workaround (which is fragile).

---

## Problem

`090-remove-gravitee.yml:181` (task 15) deletes the gravitee namespace via `kubernetes.core.k8s` with `state: absent`. That call returns once Kubernetes accepts the deletion *request*; finalizers and resource cleanup run asynchronously. The playbook exits immediately after, the wrapper logs success, and `./uis undeploy` returns exit 0 — while the namespace is still in `Terminating` phase. The very next `./uis deploy gravitee` runs `./uis secrets apply`, which tries to create `urbalurba-secrets` in the (still-Terminating) namespace and gets HTTP 403 from the API server.

## Solution

Add one task to `090-remove-gravitee.yml` after the namespace-delete task: explicitly wait for the namespace to be fully gone before returning. Use `kubectl wait --for=delete ns/<n> --timeout=120s`. Guard with an existence check so the wait is a no-op when the namespace was already gone (e.g. an interrupted prior purge).

Pattern matches the existing task 5 (wait for pods to terminate after Helm uninstall). No wrapper changes — the fix lives at the playbook layer where the deletion happens.

Other purge-mode implementations (when added to future services) follow the same pattern. No need to retrofit the 10 other namespace-deleting playbooks today — they don't have a `--purge` path or an immediate-redeploy pattern that hits the race.

---

## Phase 1: Add namespace-deletion wait to `090-remove-gravitee.yml`

### Tasks

- [x] 1.1 Open `ansible/playbooks/090-remove-gravitee.yml`. ✓
- [x] 1.2 After task 15 (`Delete gravitee namespace (purge only)`), insert a new task numbered 16. ✓ (lines 191-199)
- [x] 1.3 Renumber the existing `16. Display removal status` task to `17. Display removal status`. ✓
- [x] 1.4 Run `./uis build` to bake the updated playbook into the provision-host image. ✓ (image: `uis-provision-host:local`, manifest sha256:1fb485a7…)

### Validation

```bash
./uis exec grep -A8 'Wait for gravitee namespace to fully terminate' \
  /mnt/urbalurbadisk/ansible/playbooks/090-remove-gravitee.yml
```

Expected: the new task is present with the `kubectl wait --for=delete` line and `when: purge_mode`.

---

## Phase 2: Tester verification — back-to-back undeploy/deploy

Hand off to UIS tester via the existing `talk.md` protocol. Tester runs the exact failing scenario from Round 1.5 Issue A and confirms it now succeeds without manual intervention.

### Tasks

- [x] 2.1 Phase 2 brief appended to `talk.md` (Round 2). ✓
- [x] 2.2 Tester report received: PASS. Task 16 fired `ok` in undeploy; post-undeploy `kubectl get ns gravitee` returned `NotFound`; deploy ran clean (0 `Forbidden`/`being terminated` strings); 6/6 pods Ready in ~4 min. ✓

### Validation

Tester confirms:
- Undeploy phase emits the new "Wait for gravitee namespace to fully terminate" task and runs to ~30-60s longer than before (the wait time previously concealed in the post-exit race).
- Post-undeploy `kubectl get ns gravitee` returns `NotFound` (namespace fully gone before undeploy returned).
- `./uis deploy gravitee` proceeds without any "namespace is being terminated" error.
- All 6 pods reach Ready in the usual ~3 min.

---

## Acceptance Criteria

- [x] `./uis undeploy gravitee --purge --yes` does not return until the gravitee namespace is in `NotFound` (or fully gone). ✓ confirmed by tester
- [x] `./uis undeploy gravitee --purge --yes && ./uis deploy gravitee` works back-to-back from a single shell line, no manual wait. ✓ confirmed by tester
- [x] No regression on the default (non-purge) `./uis undeploy gravitee` path — `when: purge_mode` gating makes the change structurally inert in default mode (skipped formal regression test per maintainer direction). ✓
- [x] No changes to other remove playbooks or to `service-deployment.sh`. ✓ single-file diff

---

## Files to Modify

- `ansible/playbooks/090-remove-gravitee.yml` — one new task inserted at position 16, existing task 16 renumbered to 17.

---

## Implementation Notes

**Why playbook-level, not wrapper-level.** Adding a centralized wait in `service-deployment.sh:remove_single_service` would require each service to declare its namespace(s) in metadata so the wrapper knows what to wait for. Worth doing if multiple services start exposing `--purge` and we want a single source of truth, but premature today (gravitee is the only `--purge` consumer). When the next service gets `--purge` mode, they add the same wait task following gravitee's pattern; if a third service follows, we revisit the centralization question.

**Why `if kubectl get ns … then kubectl wait` instead of `ignore_errors: true`.** The conditional makes the failure semantics explicit ("namespace already gone is fine, do nothing") and keeps real failures (e.g. timeout reached, namespace stuck terminating because of a finalizer) visible. `ignore_errors: true` would silently mask the latter.

**Why 120s timeout.** Matches task 5's pod-termination timeout. Most clusters finish namespace deletion in <30s; the longer ceiling protects against PVC finalizer cleanup or stuck CRDs. If 120s is regularly insufficient, that's a separate cluster-config bug worth investigating, not something this fix should paper over.

**No need for a separate PR** (per maintainer direction). This change rides along with the next gravitee-config PR, or commits to main directly — at maintainer's discretion at commit time.
