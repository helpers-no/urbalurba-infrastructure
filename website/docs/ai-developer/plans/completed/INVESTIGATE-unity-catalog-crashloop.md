# INVESTIGATE: Unity Catalog CrashLoopBackOff

**Related**: [INVESTIGATE-rancher-reset-and-full-verification](INVESTIGATE-rancher-reset-and-full-verification.md)
**Created**: 2026-02-20
**Status:** Completed
**Resolved**: 2026-02-20

## Problem

Unity Catalog server pod enters `CrashLoopBackOff` / `RunContainerError` after deployment via `./uis deploy unity-catalog`.

- PostgreSQL dependency was deployed and healthy
- The Ansible playbook runs without errors
- The pod fails to start (never becomes ready, times out after 180s)
- Undeploy works correctly

## Context

Discovered during full service verification (talk9.md, Round 6, Step 9). All other 20 testable services deploy and undeploy successfully from a clean slate after factory reset.

## Root Causes Found (3 issues)

### 1. Wrong container image
**File**: `manifests/320-unity-catalog-deployment.yaml`
- `godatadriven/unity-catalog:latest` image is broken — missing jars directory, SBT build cache under `/root/`, broken classpath
- **Fix**: Changed to official `unitycatalog/unitycatalog:latest`

### 2. Wrong security context (permission denied)
**File**: `manifests/320-unity-catalog-deployment.yaml`
- `bin/start-uc-server` is owned by UID 100 (unitycatalog user) with permissions `-r-xr-x---`
- Container was configured to run as root (UID 0), which has no execute permission on the file
- **Fix**: Changed `runAsUser: 0` to `runAsUser: 100`, `runAsGroup: 0` to `runAsGroup: 101`, set `runAsNonRoot: true`

### 3. Wrong API version in health probes
**Files**: `manifests/320-unity-catalog-deployment.yaml`, `ansible/playbooks/320-setup-unity-catalog.yml`
- Health probes and API calls used `/api/1.0/unity-catalog/catalogs` which returns 404
- Actual API endpoint is `/api/2.1/unity-catalog/catalogs`
- **Fix**: Updated all API paths from `/api/1.0/` to `/api/2.1/` (3 probes in manifest + 7 occurrences in playbook)

### 4. No curl in container (playbook API tests broken)
**File**: `ansible/playbooks/320-setup-unity-catalog.yml`
- The `unitycatalog/unitycatalog:latest` image uses BusyBox which has `wget` but not `curl`
- All `kubectl exec ... -- curl` commands failed with "executable file not found"
- Fixed 30-second pause was insufficient for Unity Catalog startup (needs 2-3 minutes)
- **Fix**: Replaced `curl` with `wget -S` for HTTP status checks and `wget --post-data` for catalog creation. Replaced fixed pause with retry loop (18 retries, 10s apart).

## Verification

After all 4 fixes, Unity Catalog deploys successfully:
- Pod status: 1/1 Running, 0 restarts
- Health check passes on `/api/2.1/unity-catalog/catalogs`
- PostgreSQL connection works correctly
- API connectivity test: `Working (HTTP 200)`
- Catalog creation test: `Success`
- Verified by tester in talk9.md Rounds 7 and 8
