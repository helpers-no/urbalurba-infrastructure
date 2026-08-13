# PLAN: per-instance rows in `./uis status` + `./uis list` for multi-instance services

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Completed (talk56 R1-R7 all PASS after R4 fix)

**Goal**: Make multi-instance service deployments individually visible in `./uis status` and `./uis list`. After this PLAN ships, deploying `postgrest --app atlas` + `postgrest --app railway` produces two rows in the status table (`atlas-postgrest`, `railway-postgrest`) instead of a single binary `postgrest ✅ Healthy` row, so the user can identify each instance by its Kubernetes Service name — the same string they need for `./uis network expose tailscale <name>`.

**Last Updated**: 2026-05-15

**Investigation**: [INVESTIGATE-cli-status-multi-instance](INVESTIGATE-cli-status-multi-instance.md) — all 5 open questions answered; C-1 through C-8 locked.

**Prerequisites**: None — independent of any in-flight work. Touches `provision-host/uis/lib/` + `provision-host/uis/manage/uis-cli.sh` only.

**Priority**: Medium — operationally useful for the customer-onboarding flow (per [INVESTIGATE-docs-customer-onboarding-database](../backlog/INVESTIGATE-docs-customer-onboarding-database.md)), no production-blocking impact.

---

## Problem Summary

`cmd_status` and `cmd_list` both iterate the service registry and run each service's `SCRIPT_CHECK_COMMAND`. For multi-instance services like postgrest, that check is a single binary "is any matching deployment ready?" — collapsing N deployed instances into one row. The user cannot see from the status output how many instances exist, which apps own them, or what Kubernetes Service name to type into `./uis network expose tailscale <name>`.

The fix lands per-instance iteration for services flagged `SCRIPT_MULTI_INSTANCE="true"`, using the Kubernetes deployment name (`<app>-<service>`) as the row ID — the actionable identifier in every downstream CLI.

See the INVESTIGATE for evidence, root-cause confirmation, and the rejected alternatives.

---

## Phase 1: Helper consolidation (C-1)

Today there are two functionally identical helpers checking `multiInstance` on a service's `services.json` entry: `_is_service_multi_instance` (in `provision-host/uis/lib/service-deployment.sh:77`) and `_is_multi_instance` (in `provision-host/uis/lib/configure.sh:42`). Consolidate into one canonical helper before touching status/list code, so the iteration logic in later phases has exactly one source of truth.

### Tasks

- [x] 1.1 Delete `_is_multi_instance` from `provision-host/uis/lib/configure.sh:42-52`.
- [x] 1.2 Update the call site at `provision-host/uis/lib/configure.sh:216` from `_is_multi_instance "$service_id"` to `_is_service_multi_instance "$service_id"`.
- [x] 1.3 Ensure `lib/configure.sh` sources `lib/service-deployment.sh` (or that both are loaded by the same caller). Check `provision-host/uis/manage/uis-cli.sh` to confirm load order; if `configure.sh` is loaded before `service-deployment.sh`, swap them so `_is_service_multi_instance` is defined when `configure.sh:216` runs.

### Validation

```bash
bash -n provision-host/uis/lib/configure.sh
bash -n provision-host/uis/lib/service-deployment.sh
bash provision-host/uis/tests/run-tests.sh
grep -nR "_is_multi_instance\b" provision-host/uis/   # expect: no matches
grep -nR "_is_service_multi_instance\b" provision-host/uis/   # expect: 1 def + ≥3 callers
```

User confirms phase is complete.

---

## Phase 2: Per-instance iteration helper (C-2)

Add a new helper in `lib/service-scanner.sh` (next to `check_service_deployed`) that lists the actual Kubernetes Deployments backing a multi-instance service. The helper is a *display-side override* — only called by `cmd_status` and `cmd_list` for rendering rows. `SCRIPT_CHECK_COMMAND` on the service script and the existing `check_service_deployed` path are unchanged (deploy/undeploy/dep-check paths still use them).

### Tasks

- [x] 2.1 Add `get_multi_instance_deployments <service_id>` to `provision-host/uis/lib/service-scanner.sh`. Reads `SCRIPT_NAMESPACE` and `SCRIPT_ID` from the service script (same source-parse pattern as `check_service_deployed`). Runs:
  ```bash
  kubectl get deploy -n "$SCRIPT_NAMESPACE" -l "app.kubernetes.io/name=$SCRIPT_ID" --no-headers 2>/dev/null
  ```
  Emits one tab-separated line per deployment: `<name>\t<ready>` (e.g., `atlas-postgrest\t2/2`). Returns 0 on success (including the zero-row case); returns non-zero only on internal failure (e.g., service script not found).

- [x] 2.2 Add a tiny health-classifier helper `_classify_ready_count <ready>` (also in `lib/service-scanner.sh`) that returns:
  - `0` (healthy) iff input matches `^([1-9][0-9]*)/\1$`
  - `1` (degraded) iff input matches `^[0-9]+/[0-9]+$` but not the healthy regex
  - `2` (unknown — kubectl returned an unexpected shape) otherwise

  Used by both `cmd_status` and `cmd_list` to decide what icon to print.

- [x] 2.3 Document the helpers' contract in the file header comment of `service-scanner.sh` (which already documents `check_service_deployed` and `get_all_service_ids`).

### Validation

```bash
bash -n provision-host/uis/lib/service-scanner.sh
bash provision-host/uis/tests/run-tests.sh
# Manual smoke (inside provision-host container with a deployed postgrest):
source provision-host/uis/lib/service-scanner.sh
source provision-host/uis/lib/integration-testing.sh   # for SERVICES_DIR
get_multi_instance_deployments postgrest
# Expected output for two-app deploy:
# atlas-postgrest    2/2
# railway-postgrest  2/2
```

User confirms phase is complete.

---

## Phase 3: `cmd_status` integration (C-3, partial C-4)

Wire the new helper into `cmd_status` so multi-instance services emit per-instance rows. Single-instance services keep their existing path — no change to single-instance behaviour.

### Tasks

- [x] 3.1 In `provision-host/uis/manage/uis-cli.sh:262` (`cmd_status`), after the `source "$script"` line that loads service metadata, branch on `_is_service_multi_instance "$service_id"`:
  - **single-instance** (today's path, unchanged): run `check_service_deployed`, emit one row with `SCRIPT_ID`.
  - **multi-instance** (new path): call `get_multi_instance_deployments "$service_id"`, iterate the tab-separated output, classify each row's ready count, and emit one row per **healthy** deployment using the deployment name as the ID:
    ```
    printf "%-18s %-20s %-12s %s\n" "$deployment_name" "${SCRIPT_NAME:0:20}" "${SCRIPT_CATEGORY:0:12}" "✅ Healthy"
    ```
  - Skip degraded deployments and the zero-row case — matches `cmd_status`'s today-behaviour of "only show healthy services."

- [x] 3.2 Bump the ID column width from `%-15s` to `%-18s` (in both the header line at line 275 and the row print at line 291). `atlas-postgrest` (15 chars) and `railway-postgrest` (17 chars) fit cleanly at 18; provides headroom for typical `<app>-<service>` names. Update the underline separator on line 276 to match the new width if it depends on the format.

- [x] 3.3 Verify `has_deployed` flag still flips to `true` when any multi-instance row is emitted, so the "No deployed services found" fallback doesn't fire incorrectly.

### Validation

```bash
bash -n provision-host/uis/manage/uis-cli.sh
bash provision-host/uis/tests/run-tests.sh

# Manual smoke inside the container with a fresh build:
./uis stop && ./uis build && ./uis pull   # (contributor side — tester runs the actual deploys later)
```

User confirms phase is complete (visual review of the status output format on a local cluster).

---

## Phase 4: `cmd_list` integration (C-4 + degraded/zero cases per C-2 table)

Same iteration helper, different presentation policy. `cmd_list` always emits a row for every service in the registry, so the multi-instance path needs explicit handling for the degraded and zero-instance cases.

### Tasks

- [x] 4.1 In `provision-host/uis/manage/uis-cli.sh:195` (`cmd_list`), in the per-service block (currently around lines 234-244), branch on `_is_service_multi_instance "$service_id"`:
  - **single-instance** (today's path, unchanged): existing `check_service_deployed` → emit `✅ Deployed` / `❌ Not deployed` / `○ No check`.
  - **multi-instance** (new path): call `get_multi_instance_deployments "$service_id"`, iterate the output:
    - For each row classified healthy (`2/2`): emit one row with deployment name as ID, status `✅ Deployed`.
    - For each row classified degraded (`1/2`): emit one row with deployment name as ID, status `⚠ Degraded (<ready>/<replicas>)`.
    - If the helper returned zero rows: emit one row with `$SCRIPT_ID` as ID, status `❌ Not deployed` (so the service-type stays visible in the registry).

- [x] 4.2 Reuse the same `%-18s` column width bump from 3.2.

### Validation

```bash
bash -n provision-host/uis/manage/uis-cli.sh
bash provision-host/uis/tests/run-tests.sh
```

User confirms phase is complete (visual review of the list output on a local cluster: deployed instance, degraded instance, undeployed service-type all render correctly).

---

## Phase 5: Tests (C-8)

Add a focused static test for the helper output parsing. Integration coverage is deferred to tester verification.

### Tasks

- [x] 5.1 Add `provision-host/uis/tests/static/test-multi-instance-parsing.sh`. Tests:
  - `_classify_ready_count "2/2"` → 0 (healthy)
  - `_classify_ready_count "1/2"` → 1 (degraded)
  - `_classify_ready_count "0/2"` → 1 (degraded — zero replicas ready is degraded, not unknown)
  - `_classify_ready_count "0/0"` → 1 (degraded — counts as not-fully-ready)
  - `_classify_ready_count ""` → 2 (unknown)
  - `_classify_ready_count "garbage"` → 2 (unknown)
  - A sample kubectl-output fixture (saved as a heredoc in the test) parses into the expected tab-separated rows.

- [x] 5.2 Wire the new test into `provision-host/uis/tests/run-tests.sh` if it doesn't auto-discover `static/test-*.sh` files (check current discovery behaviour first).

### Validation

```bash
bash provision-host/uis/tests/static/test-multi-instance-parsing.sh   # explicit run
bash provision-host/uis/tests/run-tests.sh                            # full suite
```

User confirms tests pass.

---

## Phase 6: Local verification + build for tester fast-loop

- [x] 6.1 `bash -n` clean on all touched files: `service-scanner.sh`, `service-deployment.sh`, `configure.sh`, `uis-cli.sh`, the new test.
- [x] 6.2 `bash provision-host/uis/tests/run-tests.sh` — all test scripts pass.
- [x] 6.3 `cd website && npm run build` — `[SUCCESS]` (no docs touched in this PLAN, but build catches any accidental sidebar / markdown breakage).
- [x] 6.4 **Build the local image for tester consumption**: run `./uis build` from the repo root. Produces `uis-provision-host:local` on the local Docker daemon — the same daemon the tester's `./uis` invocations talk to. This is the fast-loop pattern: tester runs `UIS_IMAGE=uis-provision-host:local ./uis ...` and sees this PLAN's code immediately, no GHCR wait.
- [x] 6.5 Quick contributor-side smoke (optional, separate from the tester's round): with the running container swapped to `:local`, run `./uis status` + `./uis list` against the contributor's rancher-desktop cluster — quick sanity check that startup doesn't error.

### Validation

User confirms phase is complete (`./uis build` finishes clean; `docker images uis-provision-host:local` shows the new image with a recent timestamp).

---

## Phase 7: Tester verification round (on `uis-provision-host:local`, not `:latest`)

A talk round against the tester's rancher-desktop cluster covering the deploy → expose flow, running against the locally-built image from Phase 6.4 — no GHCR rebuild wait.

### Tasks

- [x] 7.1 Archive current `testing/uis1/talk/talk.md` → `talkNN.md` per the talk.md naming protocol.
- [x] 7.2 Write a fresh `talk.md` for this round. Brief covers:
  - **Pre-flight (local-build fast-loop)**:
    ```bash
    # Confirm the contributor's locally-built image is on this Docker daemon:
    docker images ghcr.io/helpers-no/uis-provision-host uis-provision-host
    # Expect: a `uis-provision-host:local` tag with a recent timestamp.

    # Stop the running container and start it on the local image:
    ./uis stop
    UIS_IMAGE=uis-provision-host:local ./uis start

    # All subsequent commands in this round must run with the same env var
    # (the wrapper passes UIS_IMAGE through to docker exec).
    ```
    **Do NOT `./uis pull`** for this round — `:latest` on GHCR is stale until this PLAN merges; we're testing the locally-built image against the cluster.

  - **R1 — Deploy two postgrest instances**: `UIS_IMAGE=uis-provision-host:local ./uis configure postgrest --app atlas --database atlas --schemas api_v1` + `UIS_IMAGE=... ./uis deploy postgrest --app atlas`. Repeat for `--app railway`. Verify both deployments come up.
  - **R2 — `./uis status` shows two rows**: confirm output contains `atlas-postgrest ... ✅ Healthy` and `railway-postgrest ... ✅ Healthy` on separate rows. Column alignment holds.
  - **R3 — `./uis list` shows the same two rows under INTEGRATION**. Single-instance services (postgresql, nginx) still render unchanged.
  - **R4 — Degraded case**: `kubectl scale deploy -n postgrest atlas-postgrest --replicas=0`. Verify `./uis list` shows `atlas-postgrest ... ⚠ Degraded (0/0)` or `0/2`; `./uis status` shows no `atlas-postgrest` row (only `railway-postgrest` if it's healthy). Restore with `--replicas=2`.
  - **R5 — Zero-instance case**: `./uis undeploy postgrest --app atlas` + `./uis undeploy postgrest --app railway`. Verify `./uis list` shows a single `postgrest ... ❌ Not deployed` row for the service-type; `./uis status` shows no postgrest row.
  - **R6 — Single-instance regression**: `./uis status` + `./uis list` still render single-instance services (nginx, traefik, postgresql) exactly as before this PLAN. No drift.
  - **R7 — Tailscale expose flow** (proves the team-share use case the INVESTIGATE motivated): deploy two postgrest instances; run `./uis status`; pick `railway-postgrest` from the output; run `./uis network expose tailscale railway-postgrest`. Verify it works end-to-end against the public Funnel URL.

- [x] 7.3 Iterate on findings as small follow-up commits on the same branch if R1–R7 surface anything. The contributor re-runs `./uis build` after each commit; tester's next round picks up the new `:local` image immediately (the wrapper re-creates the container on `start`).

### Validation

Tester closes the round with all R1–R7 PASS. Any FAIL findings filed as F-findings in the talk.md and resolved on the same branch before this PLAN merges. **After merge**, the GHCR `Build UIS Container` workflow produces a fresh `:latest` carrying the verified code — no separate re-verification round needed since `:local` and the post-merge `:latest` are built from the same commit.

---

## Acceptance Criteria

- [x] `./uis status` shows one row per healthy multi-instance deployment, with the deployment name (e.g., `atlas-postgrest`) as the row ID.
- [x] `./uis status` skips degraded multi-instance deployments (consistent with today's single-instance "check failed → no row" behaviour).
- [x] `./uis list` shows one row per multi-instance deployment, with explicit `✅ Deployed` / `⚠ Degraded` / `❌ Not deployed (service-type)` states per the C-2 table.
- [x] Single-instance services in both commands render exactly as they did before this PLAN — no drift.
- [x] `_is_service_multi_instance` is the single canonical helper; `_is_multi_instance` is deleted.
- [x] `SCRIPT_CHECK_COMMAND` on `service-postgrest.sh` is unchanged; `check_service_deployed` behaviour for deploy/undeploy/dep-check paths is unchanged.
- [x] Local `bash -n` + `bash provision-host/uis/tests/run-tests.sh` + `cd website && npm run build` all pass.
- [x] Tester round R1–R7 closes PASS.
- [x] This plan is in `completed/`.

---

## Files to Modify

- `provision-host/uis/lib/service-scanner.sh` — add `get_multi_instance_deployments` + `_classify_ready_count`; update header doc.
- `provision-host/uis/lib/configure.sh` — delete `_is_multi_instance` (lines 42-52); update call site at line 216.
- `provision-host/uis/lib/service-deployment.sh` — no functional change (existing `_is_service_multi_instance` stays canonical).
- `provision-host/uis/manage/uis-cli.sh` — branch on multi-instance in `cmd_status` (line 262) and `cmd_list` (line 195); bump ID column width to `%-18s`.
- `provision-host/uis/tests/static/test-multi-instance-parsing.sh` — new test (Phase 5).
- `testing/uis1/talk/talk.md` — fresh round per Phase 7 (handled at PLAN-execution time, not in the code PR).

---

## Implementation Notes

- **Helper placement.** `get_multi_instance_deployments` belongs in `lib/service-scanner.sh` alongside `check_service_deployed` because both are "introspect a service against the current cluster" primitives. Keep them together so future readers see the single/multi pair as the two display paths.

- **Reading service metadata.** `check_service_deployed` parses `SCRIPT_CHECK_COMMAND` by `while IFS= read -r line` line-scanning the service script — it avoids `source`-ing the script to skirt side-effects. The new `get_multi_instance_deployments` needs `SCRIPT_NAMESPACE` and `SCRIPT_ID`, which are also simple `=`-assignments at the top of the script. Use the same line-scan pattern for consistency. (cmd_status itself does source the script, but that's already a known cost in the calling context.)

- **Column width choice.** `%-18s` covers `railway-postgrest` (17) with one char of headroom. Longer `<app>-<service>` names will still overflow without truncation (bash `printf` minimum-width semantics). If the PLAN's tester round surfaces a real name that's wider, the format is easy to bump again; don't pre-optimise.

- **Degraded vs unknown ready-count.** A deployment that shows `0/0` happens transiently right after a scale-to-zero or a fresh apply. Treating `0/0` as "degraded" (rather than "unknown") matches the operator's intent — "I deployed this and it isn't ready." Only truly malformed kubectl output (`<no value>`, garbage) maps to unknown.

- **Don't add a new metadata field.** `SCRIPT_MULTI_INSTANCE="true"` + `SCRIPT_NAMESPACE` already on the service script are sufficient. The PLAN keeps the contract narrow.

- **Backwards compatibility.** Documented in C-5 — scripts that grep `^postgrest` will no longer match after this lands. Document the migration in the PR body; the cost is acceptable since `./uis status` is interactive, not script-driven.

- **Per-app namespace future case (C-7).** If a future multi-instance service ever needs to deploy each instance into its own namespace, the iteration in `get_multi_instance_deployments` will need extending (it'd need to query across namespaces, or read namespace from a different field). Out of scope here; flagged so the contract doesn't get reused incorrectly.

- **Local-build fast-loop for the tester round (Phase 7).** Don't merge → wait 12+ min for the GHCR `Build UIS Container` workflow → tell tester to `./uis pull`. Instead: run `./uis build` locally after Phase 6.5 passes; the resulting `uis-provision-host:local` image is on the same Docker daemon the tester uses, so they run `UIS_IMAGE=uis-provision-host:local ./uis ...` and see this PLAN's code with zero CI wait. Iterations within the round (fix → re-build → tester re-tests) take seconds instead of minutes. After Phase 7 closes green, merge the PR; the GHCR rebuild then produces a `:latest` from the same commit the tester already verified, so no separate post-merge regression round is needed.
