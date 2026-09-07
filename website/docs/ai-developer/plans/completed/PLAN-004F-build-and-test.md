# PLAN-004F: Build and Test UIS System

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed — ✅ Complete
**Parent:** PLAN-004 (UIS Orchestration System)
**Created:** 2025-01-22
**Completed:** 2025-01-22
**Prerequisites:** PLAN-004A through PLAN-004E complete

## Overview

Build the uis-provision-host container with all new UIS orchestration code and validate the complete system works end-to-end.

## Goals

1. Build container with all UIS code
2. Run static and unit tests
3. Validate CLI commands work
4. Validate JSON generation
5. Test service deployment cycle

---

## Critical Bug Fixed: `((var++))` with `set -e`

During testing, discovered that `((var++))` (post-increment) returns exit code 1 when `var=0`, because it returns the old value (0 = falsy). This causes scripts with `set -e` to abort unexpectedly.

**Fix:** Change `((var++))` to `((++var))` (pre-increment returns new value, always truthy when incrementing from 0).

**Files fixed:**
- `uis-cli.sh` - `((count++))`, `((pos++))`
- `categories.sh` - `((order++))`
- `stacks.sh` - `((i++))`, `((count++))`, `((pos++))`
- `menu-helpers.sh` - `((i++))`
- `service-deployment.sh` - `((failed++))`

**Test added:** `tests/static/test-arithmetic.sh` - Detects this pattern in all scripts with `set -e`

---

## Phase 1: Pre-Build Validation — ✅ DONE

### 1.1 Run Static Tests (No Container Needed)

```bash
# Syntax check all shell scripts
./provision-host/uis/tests/run-tests.sh static
```

**Result:** ✅ 187 tests passed (syntax, metadata, categories, JSON validation, arithmetic patterns)

### 1.2 Validate JSON Schemas

```bash
# Run schema validation
./provision-host/uis/tests/validate-schemas.sh
```

**Result:** ✅ All 4 JSON files validate against schemas (24 services, 10 categories, 3 stacks, 7 tools)

---

## Phase 2: Build Container — ✅ DONE

### 2.1 Build uis-provision-host Container

```bash
# Build the container locally
docker build -t uis-provision-host:test -f Dockerfile.uis-provision-host .
```

**Result:** ✅ Container built successfully (all provisioning scripts completed)

### 2.2 Verify UIS Code in Container

```bash
# Check that UIS files are present
docker run --rm uis-provision-host:test ls -la /mnt/urbalurbadisk/provision-host/uis/
```

**Result:** ✅ All directories present:
- `lib/` - 12 library files (categories.sh, stacks.sh, etc.)
- `manage/` - uis-cli.sh, uis-docs.sh
- `services/` - 10 category directories (ai, monitoring, databases, etc.)
- `tests/` - Test framework
- `tools/` - Tool installers

---

## Phase 3: Test CLI Commands — ✅ DONE

**Bug Fixed:** `((count++))` returns exit code 1 when count=0, causing `set -e` to abort. Fixed by using `((++count))`.

### 3.1 Start Container

```bash
# Start container with proper mounts
./uis start
```

### 3.2 Test Basic Commands

```bash
# Version and help
./uis version
./uis help

# List services
./uis list

# List stacks
./uis stack list

# Show stack info
./uis stack info observability

# Show service info
./uis info prometheus
```

**Expected:** All commands return sensible output without errors

### 3.3 Test Enable/Disable

```bash
# Enable a service
./uis enable prometheus

# Check enabled list
./uis list-enabled

# Disable the service
./uis disable prometheus

# Verify disabled
./uis list-enabled
```

**Expected:** Services can be enabled/disabled, config file updates correctly

---

## Phase 4: Test JSON Generation — ✅ DONE

**Bug Fixed:** `((order++))` in categories.sh, plus similar issues in stacks.sh, menu-helpers.sh, service-deployment.sh.

### 4.1 Generate JSON Files

```bash
# Run inside container or via uis command
./uis shell
cd /mnt/urbalurbadisk
./provision-host/uis/manage/uis-docs.sh generate
```

### 4.2 Validate Generated Files

```bash
# Check JSON is valid
./provision-host/uis/tests/validate-schemas.sh
```

**Expected:** All JSON files generated and valid

---

## Phase 5: Test Menu System — ⏭️ SKIPPED (Requires Interactive TTY)

The menu system requires an interactive terminal with dialog support. This cannot be tested in automated CI/CD pipelines. Manual testing can be performed with:

### 5.1 Launch Interactive Menu

```bash
./uis setup
```

**Expected:** Dialog-based menu appears with options:
- Browse & Deploy Services
- Install Optional Tools
- Cluster Configuration
- Secrets Management
- System Status

### 5.2 Test Tool Installation Menu

Navigate to "Install Optional Tools" and verify:
- Built-in tools show ✅
- Optional tools show ❌ with sizes

---

## Phase 6: Integration Tests — ⏭️ DEFERRED (Requires Kubernetes)

### 6.1 Run Unit Tests in Container

```bash
./uis shell
cd /mnt/urbalurbadisk
./provision-host/uis/tests/run-tests.sh unit
```

### 6.2 Test Service Deployment (Optional)

Only if Kubernetes cluster is running:

```bash
# Deploy a simple service
./uis deploy whoami

# Check status
./uis status

# Remove service
./uis remove whoami
```

---

## Tasks Checklist

### Pre-Build
- [x] Run static tests: `./provision-host/uis/tests/run-tests.sh static` ✓
- [x] Run schema validation: `./provision-host/uis/tests/validate-schemas.sh` ✓

### Build
- [x] Build container: `docker build -t uis-provision-host:test -f Dockerfile.uis-provision-host .` ✓
- [x] Verify files in container ✓

### CLI Tests
- [x] `./uis version` - Shows version ✓
- [x] `./uis help` - Shows help ✓
- [x] `./uis list` - Lists services with categories ✓
- [x] `./uis stack list` - Lists stacks ✓
- [x] `./uis stack info observability` - Shows stack details ✓
- [x] `./uis enable/disable` - Modifies config file ✓ (fixed `((count++))` bug)

### JSON Generation
- [x] `uis-docs.sh generate` - Generates all JSON files ✓ (fixed `((order++))` in categories.sh)
- [x] Schema validation passes ✓ (24 services, 10 categories, 3 stacks, 7 tools)

### Menu System (Requires Interactive TTY)
- [~] `./uis setup` - Menu launches (skipped - requires interactive terminal)
- [~] Service selection works (skipped)
- [~] Tool installation menu works (skipped)

### Integration (Requires Kubernetes)
- [~] Unit tests pass in container (deferred - requires k8s cluster)
- [~] Service deploy/remove cycle works (deferred)

---

## Known Issues to Watch For

1. **Path issues**: UIS code expects to be at `/mnt/urbalurbadisk/`
2. **Bash version**: Some features need bash 4.x, container should have it
3. **Dialog missing**: Menu requires `dialog` package in container
4. **Kubeconfig mount**: CLI needs kubeconfig mounted for k8s commands

---

## Success Criteria

- [x] All static tests pass ✓ (187 tests including arithmetic pattern detection)
- [x] Container builds without errors ✓
- [x] All CLI commands work ✓
- [x] JSON generation produces valid files ✓
- [~] Menu system is functional (skipped - requires interactive TTY)
- [~] Service deployment works (deferred - requires Kubernetes cluster)

---

## Files Referenced

| File | Purpose |
|------|---------|
| `Dockerfile.uis-provision-host` | Container build definition |
| `uis` | Wrapper script |
| `provision-host/uis/manage/uis-cli.sh` | CLI entry point |
| `provision-host/uis/manage/uis-docs.sh` | JSON generator |
| `provision-host/uis/tests/run-tests.sh` | Test runner |
| `provision-host/uis/tests/validate-schemas.sh` | Schema validator |
| `provision-host/uis/tests/static/test-arithmetic.sh` | Detects `((var++))` bug pattern |
