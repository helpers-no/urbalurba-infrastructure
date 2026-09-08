# PLAN-013: `./uis test-all` — Full Integration Test Command

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: Automate the full integration test as `./uis test-all` — runs the same `./uis deploy`/`./uis undeploy` commands the manual tester runs, for all 23 services.

**Completed**: 2026-02-26
**Last Updated**: 2026-02-26

---

## Problem Summary

The full integration test requires a manual tester. The tester runs `./uis deploy <service>`, checks exit code, runs `./uis undeploy <service>`, checks exit code — for all 23 services. This should be a single command.

---

## Design: Data-Driven Test Sequence

### Existing metadata we use

Every service script already declares:
- `SCRIPT_REQUIRES` — space-separated dependency list (e.g. `"postgresql redis"`)
- `SCRIPT_PRIORITY` — numeric deployment order (lower = earlier)
- `SCRIPT_ID` — service identifier

The test script reads these from the service scripts via `service-scanner.sh` functions that already exist (`get_all_service_ids`, `find_service_script`).

### How the test sequence is built

1. **Scan all services** using `get_all_service_ids` (already sorts by priority)
2. **Skip services** in a skip list: `SKIP_SERVICES="gravitee tailscale-tunnel cloudflare-tunnel"`
3. **Topological deploy order** — sort by `SCRIPT_PRIORITY`, then resolve `SCRIPT_REQUIRES` so dependencies deploy first
4. **Undeploy in reverse** — services without dependents undeploy first; shared deps (postgresql, redis, nginx) undeploy last

### Three service roles

| Role | Meaning | Example |
|------|---------|---------|
| **foundation** | Deploy first, undeploy last. Never undeployed mid-test. | nginx, postgresql, redis |
| **regular** | Deploy, test, undeploy. Dependencies must be running. | whoami, authentik, grafana |
| **skip** | Not tested (needs external config). | gravitee, tailscale-tunnel, cloudflare-tunnel |

Foundation services are those that appear in other services' `SCRIPT_REQUIRES` (computed automatically). A service that nothing depends on is "regular".

### Test execution order (computed, not hardcoded)

```
1. Deploy all foundation services (sorted by priority)
2. For each regular service (sorted by priority):
   a. Deploy  → record PASS/FAIL
   b. If service has a verify command (e.g. argocd): run it → record PASS/FAIL
   c. Undeploy → record PASS/FAIL
3. Undeploy all foundation services (reverse priority order)
```

### Extensibility

When a new service is added to `provision-host/uis/services/`:
- If it has no `SCRIPT_REQUIRES` and nothing depends on it → automatically tested as "regular"
- If other services depend on it → automatically promoted to "foundation"
- If it needs external config → add its ID to the skip list (one line change)

No hardcoded service lists to maintain except the skip list.

### Output design

Deploy/undeploy commands produce lots of Ansible and kubectl output. All of it streams normally so the user can follow along live. The test script adds clear marker lines with timestamps and a step counter before and after each operation, plus a summary table at the end.

**Before each operation** — bold banner with timestamp and progress:

```
══════════════════════════════════════════════════════════════
[14:30:12] STEP 4/47: deploy whoami
══════════════════════════════════════════════════════════════
```

*...all normal ansible/kubectl output flows here...*

**After each operation** — result line with duration:

```
[14:30:37] RESULT: deploy whoami — PASS (25s)
```

**After all operations** — summary table:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Test Summary
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Finished: 2026-02-26 08:41:05
Duration: 38m 40s

SERVICE              DEPLOY     UNDEPLOY   VERIFY
─────────────────────────────────────────────────────────
prometheus           PASS       PASS       -
loki                 PASS       PASS       -
...
argocd               PASS       PASS       PASS
─────────────────────────────────────────────────────────
Result: ALL PASSED (47/47 operations)
```

### Log file

All console output (markers + ansible/kubectl output) is captured to a log file using `tee`. The log file path is printed at the start and end of the run.

```
Log file: /tmp/uis-test-all-2026-02-26-080225.log
```

### Failure behavior: stop on first failure

The test stops immediately when any operation returns a non-zero exit code. The summary table shows what passed and which operation failed.

### Clean state check

Before running, the test checks if any services are currently deployed. If the cluster is not clean, it refuses to run and tells the user to use `--clean`:

```
ERROR: Cluster is not in a clean state. The following services are deployed:
  - nginx
  - postgresql

Run with --clean to undeploy all services first:
  ./uis test-all --clean
```

With `--clean`, all deployed services are undeployed in reverse priority order before starting the test.

---

## Phase 1: Create Test Script — DONE

### Tasks

- [x] 1.1 Create `provision-host/uis/lib/integration-testing.sh` with:
  - `build_test_plan()` — scans services, computes foundation/regular/skip sets, returns ordered plan
  - `run_integration_tests()` — executes the plan, records results
  - `print_test_summary()` — prints PASS/FAIL table and totals

- [x] 1.2 Implementation details:
  - Use `get_all_service_ids` + `find_service_script` to scan (from `service-scanner.sh`)
  - Source each service script to read `SCRIPT_REQUIRES` and `SCRIPT_PRIORITY`
  - Compute foundation set: any service ID that appears in another service's `SCRIPT_REQUIRES`
  - Skip list: `SKIP_SERVICES="gravitee tailscale-tunnel cloudflare-tunnel"` (single variable, easy to edit)
  - Call `uis-cli.sh deploy <service>` / `uis-cli.sh undeploy <service>` as subprocesses
  - Check exit code (0 = PASS, non-zero = FAIL)
  - Stop on first failure — print summary of what passed and what failed, then exit 1
  - For argocd: also run `uis-cli.sh argocd verify` between deploy and undeploy
  - Track results in arrays: service name, command (deploy/undeploy/verify), result (PASS/FAIL)
  - Capture all output (markers + ansible/kubectl) to log file via `tee`
  - Print log file path at start and end of run

- [x] 1.3 Support `--dry-run` flag — print the computed test plan without executing

- [x] 1.4 Support `--clean` flag — check for clean state, undeploy all if --clean passed

---

## Phase 2: Wire Into CLI — DONE

### Tasks

- [x] 2.1 Add `source "$LIB_DIR/integration-testing.sh" 2>/dev/null || true` to `uis-cli.sh`
- [x] 2.2 Add `cmd_test_all()` function that calls `run_integration_tests "$@"`
- [x] 2.3 Add `test-all)` case to the command router in `main()`
- [x] 2.4 Add to help text under a new "Testing:" section

---

## Phase 3: Build and Test — DONE

### Tasks

- [x] 3.1 Build image
- [x] 3.2 Tester runs `./uis test-all --clean` on cluster
- [x] 3.3 All 23 services pass — 47/47 operations PASS in 38m 40s

---

## Acceptance Criteria

- [x] `./uis test-all` runs deploy/undeploy for all 23 services using regular `./uis` commands
- [x] `./uis test-all --dry-run` shows the computed plan without executing
- [x] `./uis test-all --clean` undeploys all services first, then runs tests
- [x] Test order respects `SCRIPT_REQUIRES` dependencies (foundations first, dependents after)
- [x] Stops on first failure with summary of what passed and what failed
- [x] All output captured to log file (path printed at start and end)
- [x] Summary table at end with PASS/FAIL per service per operation
- [x] Timestamps and duration on every operation
- [x] Exit code 0 = all pass, 1 = any fail
- [x] Adding a new service requires zero changes (unless it needs to be skipped)

---

## Files Modified

| File | Action |
|------|--------|
| `provision-host/uis/lib/integration-testing.sh` | **Created** — test orchestration |
| `provision-host/uis/manage/uis-cli.sh` | Added source, command, help text |
| `provision-host/uis/services/monitoring/service-otel-collector.sh` | Fixed `SCRIPT_REQUIRES` to include prometheus, loki, tempo |
| `provision-host/uis/services/monitoring/service-grafana.sh` | Fixed `SCRIPT_REQUIRES` to include prometheus, loki, tempo, otel-collector |

## Bugs Fixed During Implementation

- `((var++))` with `set -e` kills script when var is 0 (post-increment returns falsy) — use `var=$((var + 1))`
- Kubernetes namespace deletion race condition — added 5s sleep after undeploy
- Word splitting in `VERIFY_SERVICES` — changed from `for entry in` to `while IFS= read -r`
- otel-collector and grafana `SCRIPT_REQUIRES` were incomplete — needed full observability stack as dependencies
