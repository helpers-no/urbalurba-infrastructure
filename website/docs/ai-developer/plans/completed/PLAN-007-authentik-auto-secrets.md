# PLAN-007: Authentik Automatic Secrets Application

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: Make Authentik deployment fully automatic by applying secrets at the start of the playbook, eliminating the need for manual `kubectl apply` before deployment. Extended to include end-to-end authentication testing.

**Last Updated**: 2026-01-31

**Branch**: `feature/secrets-migration`

**Prerequisites**: None - this is a standalone fix

**Related**: [INVESTIGATE-authentik-automation.md](./INVESTIGATE-authentik-auto-deployment.md)

---

## Contributor/Tester Workflow

This plan is implemented by a **contributor** (Claude Code) with a separate **tester** (UIS-USER1).

**Communication**: Via `talk.md` file in the tester's environment (`/Users/terje.christensen/learn/projects-2026/testing/uis1/talk/talk.md`)

**Workflow**:
1. Contributor writes test instructions to `talk.md`
2. Tester executes tests and reports results back in `talk.md`
3. Contributor reads results and iterates

**Before starting implementation**:
- Rename current `talk.md` to `talk5.md` (archive previous session)
- Create new empty `talk.md` for this session

---

## Problem Statement

Currently, deploying Authentik requires a manual step:
```bash
kubectl apply -f .uis.secrets/generated/kubernetes/kubernetes-secrets.yml
```

Without this, the playbook fails because:
1. The `authentik` namespace doesn't exist
2. The `urbalurba-secrets` secret doesn't exist in the namespace
3. The database utility can't read the password
4. Helm deployment fails (pods crash)

The generated `kubernetes-secrets.yml` already contains the namespace and secrets - the playbook just needs to apply it.

---

## Solution

Add an early step to `070-setup-authentik.yml` that applies the secrets file before checking for prerequisites.

### Before (fails)
```
1. Check namespace exists → FAIL
2. Check secrets exist → FAIL
3. ...
```

### After (works)
```
1. Apply secrets file (creates namespace + secrets)
2. Check namespace exists → PASS
3. Check secrets exist → PASS
4. ...
```

---

## Phase 0: Setup — COMPLETE

### Tasks

- [x] 0.1 Rename `talk.md` to `talk5.md` (archive previous session)
- [x] 0.2 Create new empty `talk.md` with session header for PLAN-007

---

## Phase 1: Update Playbook — COMPLETE

### Tasks

- [x] 1.1 Add new task to apply secrets file early in `070-setup-authentik.yml`

  **Implementation note:** Changed from `kubernetes.core.k8s` module to `kubectl apply` command because the k8s module has issues with multi-document YAML files.

  ```yaml
  - name: "1.5. Apply secrets file to create namespace and credentials"
    ansible.builtin.command: >
      kubectl apply -f {{ secrets_file }}
    environment:
      KUBECONFIG: "{{ merged_kubeconf_file }}"
    register: secrets_apply_result

  - name: "1.6. Display secrets application status"
    ansible.builtin.debug:
      msg: |
        ✅ Secrets applied successfully
        📁 Source: {{ secrets_file }}
        🔧 Created: authentik namespace and urbalurba-secrets
  ```

- [x] 1.2 Update the playbook header comment to reflect that secrets are auto-applied

- [x] 1.3 Test deployment with `./uis deploy authentik`
  - Fresh cluster (no authentik namespace) ✅
  - Succeeded without manual steps ✅

- [x] 1.4 Test removal with `./uis undeploy authentik`
  - Works as before ✅

---

## Phase 2: Update Documentation — COMPLETE

### Tasks

- [x] 2.1 Update `INVESTIGATE-authentik-automation.md` to mark Goal 1 complete

- [x] 2.2 Test results documented in `talk.md`

---

## Phase 3: Fix Authentik Redirect URL — COMPLETE

### Problem

When authenticating via Authentik forward auth, the redirect URL goes to `http://authentik-server.authentik.svc.cluster.local` (internal Kubernetes URL) instead of `http://authentik.localhost`.

**Root Cause:** Authentik bug #5922 - the embedded outpost **ignores `authentik_host_browser`** for OAuth redirects. It uses `authentik_host` for all browser-facing redirects.

**Status:** Bug was closed as "not planned" (won't fix) by Authentik team.

### Tasks

- [x] 3.1 Investigate where `authentik_host_browser` should be configured
  - Initial finding: Added `config` section with `authentik_host_browser` to blueprint
  - Issue: Template rendered correctly but redirect still wrong

- [x] 3.2 Deep debugging of embedded outpost behavior
  - Verified outpost database config shows correct `authentik_host_browser`
  - Tested with `AUTHENTIK_HOST_BROWSER` environment variable - no effect
  - Discovered Authentik bug #5922: embedded outpost ignores `authentik_host_browser`

- [x] 3.3 Implement workaround for Authentik bug #5922
  - Set `authentik_host` (not just `authentik_host_browser`) to external URL
  - Embedded outpost can still reach server locally (same pod)
  - Tested manually - redirect now goes to `http://authentik.localhost`

- [x] 3.4 Update blueprint template with permanent fix
  - Updated `manifests/073-authentik-service-protection-blueprint.yaml.j2`
  - Changed outpost config:
    ```yaml
    config:
      authentik_host: {{ domains.localhost.protocol }}://authentik.{{ domains.localhost.base_domain }}
      authentik_host_browser: {{ domains.localhost.protocol }}://authentik.{{ domains.localhost.base_domain }}
    ```

- [x] 3.5 Rebuild container and verify fix persists after redeploy
  - Verified during Phase 4 Round 6: full deployment from scratch with redirect working correctly

### Technical Details

**Authentik Bug #5922**: https://github.com/goauthentik/authentik/issues/5922
- Title: "Embedded proxy redirects to authentik_host, not authentik_host_browser"
- Status: Closed as "not planned" (won't fix)
- Workaround: Set `authentik_host` to external URL (embedded outpost runs in same pod)

### Limitation

The redirect URL uses the localhost domain configuration. External domains (e.g., `authentik.urbalurba.no`) would need separate outpost configuration or a standalone outpost deployment.

---

## Phase 4: End-to-End Auth Testing in Playbook — COMPLETE

### Problem

The playbook tests public and protected URLs using cluster-internal curl pods (via Traefik's internal service). These tests verify HTTP status codes (200 for public, 302 for protected) but do NOT verify:

1. The redirect URL points to `authentik.localhost` (not `0.0.0.0:9000` or an internal URL)
2. A test user can actually log in through the full OAuth flow
3. The authenticated response contains the expected auth headers

All of these were tested manually by the tester. They should be automated in the playbook.

### Solution — What Was Built

Instead of extending the existing tests inline, a **standalone test playbook** was created: `ansible/playbooks/070-test-authentik-auth.yml`. This can run independently or is called automatically by the deployment playbook at task 54.5.

The test playbook has **5 critical tests** (all must pass):

| Test | What it verifies |
|------|-----------------|
| **A** — Redirect URL Verification | Protected `whoami.localhost` → 302 redirect to `authentik.localhost` |
| **B** — Full Login Flow | 3-step API login flow for `it1@urbalurba.no` via `/api/v3/flows/executor/default-authentication-flow/` |
| **C** — Public URL Content | Public `whoami-public.localhost` returns `Hostname:` content without `X-authentik-username` header |
| **D** — Post-Login Protected Access | After login, authenticated user gets HTTP 200 from protected whoami with `X-Authentik-Username: it1` |
| **E** — Wrong Credentials Rejected | Login with `WrongPassword999` is correctly denied (no `xak-flow-redirect`) |

Additionally, task **46.5** was added to `070-setup-authentik.yml` to delete the standard `whoami` Ingress before deploying the protected IngressRoute (security fix — see issues #10 and #11 below).

### Tasks

- [x] 4.1 Add redirect URL content check (Test A)
  - Curl pod hits `whoami.localhost` via Traefik ClusterIP using `--resolve`
  - Captures `Location` header, asserts it contains `authentik.localhost`
  - CRITICAL — fails the playbook if wrong

- [x] 4.2 Add full login flow test (Test B)
  - Pre-check: queries Authentik DB to verify `it1@urbalurba.no` exists (retries 6×15s for blueprint processing)
  - 3-step API POST with `-L` (follow redirects): start flow → submit username → submit password
  - Checks for `xak-flow-redirect` success marker
  - CRITICAL — fails the playbook if login doesn't succeed

- [x] 4.3 Add public URL content verification (Test C)
  - Curl pod hits `whoami-public.localhost` via Traefik
  - Asserts body contains `Hostname:` (real whoami content)
  - Asserts no `X-authentik-username` header (public route, no auth)
  - CRITICAL

- [x] 4.4 Add post-login protected access test (Test D — added per tester feedback)
  - Logs in through `authentik.localhost` via `--resolve` (sets cookie on correct domain)
  - Hits protected `whoami.localhost` following full OAuth redirect chain
  - Verifies HTTP 200, body contains `Hostname:`, response has `X-Authentik-Username: it1`
  - CRITICAL

- [x] 4.5 Add wrong credentials rejection test (Test E — added per tester feedback)
  - Same 3-step login flow with password `WrongPassword999`
  - Asserts no `xak-flow-redirect` in response
  - CRITICAL

- [x] 4.6 Integrate test playbook into deployment
  - Task 54.5 in `070-setup-authentik.yml` calls test playbook with `failed_when: false`
  - Task 54.6 displays results (PASSED/NEEDS REVIEW with exit code)

- [x] 4.7 Fix Ingress conflict (security fix)
  - Task 46.5 deletes standard `whoami` Ingress before deploying protected IngressRoute
  - Prevents forward auth bypass when `025-setup-whoami-testpod.yml` was run first

- [x] 4.8 Bake files into container image
  - Rebuilt container with `uis-provision-host:local`
  - Both `070-test-authentik-auth.yml` and modified `070-setup-authentik.yml` baked in
  - Verified with full deployment from scratch (Round 6)

### Testing Rounds

Phase 4 went through **6 rounds** of iterative testing with UIS-USER1 via `talk.md`:

| Round | What was tested | Result | Key findings |
|-------|----------------|--------|-------------|
| **1** | Tests A, B, C standalone (docker cp) | A ✅ B ⚠️ C ✅ | Test B INCONCLUSIVE — curl missing `-L` flag, wrong success check |
| **2** | Fixed Test B (follow redirects, check `xak-flow-redirect`) | A ✅ B ✅ C ✅ | All pass. Tester requested Tests D and E |
| **3** | Added Tests D and E | A ✅ B ✅ C ✅ D ❌ E not reached | Test D failed — cookie domain mismatch |
| **4** | Fixed Test D (login through `authentik.localhost` via `--resolve`) | A ✅ B ✅ C ✅ D ✅ E ✅ | All 5 tests pass standalone |
| **5** | Container rebuild + full deployment | 5a ✅ 5b ❌ at task 52 | Standard whoami Ingress conflicts with protected IngressRoute |
| **6** | Added task 46.5 (Ingress cleanup) + full deployment | All ✅ | 81 ok, 0 failed. Task 54.5 runs E2E tests automatically |

### Technical Details

**How tests run inside the cluster:**
- Ephemeral `curlimages/curl` pods with `--rm --restart=Never`
- Route through Traefik ClusterIP using `--resolve` flag (maps hostnames without DNS)
- Pod names: `curl-test-redirect`, `curl-test-login`, `curl-test-public-content`, `curl-test-postlogin`, `curl-test-badlogin`

**How Test D works (the tricky one):**
1. Logs in through `authentik.localhost` via Traefik using `--resolve` — session cookie lands on `authentik.localhost` domain
2. Hits `whoami.localhost` through Traefik — Traefik's forward auth sends to Authentik's outpost
3. Outpost redirects to OAuth authorize endpoint on `authentik.localhost` — session cookie is present, auto-approves
4. OAuth callback sets proxy auth cookie, redirects back to protected URL
5. Protected URL returns whoami content with `X-Authentik-Username: it1`

**Why `-L` is needed on login API calls:**
Authentik's flow executor returns 302 redirects after each stage submission (identification → password → redirect). Without `-L`, curl gets empty bodies and the flow never completes.

**Cookie domain scoping:**
API login to `authentik-server.authentik.svc.cluster.local` sets cookies on that domain. OAuth authorize goes to `authentik.localhost`. The cookie domains don't match, so Authentik sees an unauthenticated request. Fix: route login through `authentik.localhost` via `--resolve`.

---

## Verification Checklist

- [x] `./uis deploy authentik` works on fresh cluster without manual steps
- [x] `./uis undeploy authentik` still works
- [x] Authentik pods start successfully
- [x] Test users are created (blueprint processed)
- [x] Forward auth middleware works
- [x] Authentication redirect goes to `authentik.localhost` (verified Test 14)
- [x] Authentication redirect fix persists after container rebuild (verified Test 14)
- [x] Task 28 database setup succeeds (exit code 0, verified Test 14)
- [x] Fail-fast stops playbook on database failure (verified Test 13)
- [x] Playbook verifies redirect URL content (Test A — verified Round 6)
- [x] Playbook performs full login flow test with test user (Test B — verified Round 6)
- [x] Playbook verifies public URL returns content without auth (Test C — verified Round 6)
- [x] Playbook verifies post-login access to protected resource (Test D — verified Round 6)
- [x] Playbook verifies wrong credentials are rejected (Test E — verified Round 6)
- [x] Standard whoami Ingress conflict resolved (task 46.5 — verified Round 6)
- [x] Full deployment completes end-to-end (81 ok, 0 failed — Round 6)
- [x] Test playbook baked into container image

---

## Rollback

If issues occur, remove the added tasks (1.5 and 1.6) from the playbook. The manual workaround still works.

---

## Implementation Notes

- This is Goal 1 from INVESTIGATE-authentik-automation
- Quick fix that can be done independently of Goal 2 (config architecture)
- The secrets file path is hardcoded to the new `.uis.secrets/` location
- Backwards compatibility with `topsecret/` is handled by the secrets generation, not this playbook

### Issues Encountered During Implementation

1. **kubernetes.core.k8s module issue**: The Ansible k8s module couldn't handle multi-document YAML files with namespace + secrets. Error: "Namespace is required for v1.Secret". **Fix**: Changed to `kubectl apply` command.

2. **Task ordering bug**: The playbook tested UI accessibility (task 35) BEFORE deploying IngressRoutes (task 38-40). **Fix**: Reordered tasks so IngressRoutes deploy first (tasks 34-36), then UI test (tasks 37-39).

3. **Duplicate task numbering**: Two tasks were numbered "45". **Fix**: Renumbered tasks 46-59.

4. **Secrets not applied after factory reset**: After a Rancher Desktop factory reset, host files (`.uis.extend/`, `.uis.secrets/`) survive but Kubernetes is wiped. The `check_first_run()` function only checks if `enabled-services.conf` exists on the host, so it skips initialization (including `apply_kubernetes_secrets()`). **Fix**: Added `ensure_secrets_applied()` function in `first-run.sh` that is called from `cmd_deploy()` on every deploy. It generates secrets if the file doesn't exist, then always applies with `kubectl apply` (idempotent).

5. **pg_hba.conf md5 vs scram-sha-256 mismatch**: Bitnami PostgreSQL chart v18+ generates `pg_hba.conf` with `md5` auth, but PostgreSQL 16 defaults to `scram-sha-256` password encryption. Password set during init is stored as scram-sha-256 hash, but md5 auth can't verify it. **Fix**: Added `pgHbaConfiguration` with `scram-sha-256` to `042-database-postgresql-config.yaml`.

6. **Bash escaping `!` in passwords**: Bitnami init script passes passwords through bash, which escapes `!` (history expansion) to `\!`. Password `LocalDevDB456!` was stored as `LocalDevDB456\!` in PostgreSQL. **Fix**: Removed `!` from all default passwords. Documented password restriction (no `!  $  \`  \  "`) in three files.

7. **Helm chart not version-pinned**: `helm install postgresql bitnami/postgresql` with no `--version` flag caused unpredictable behavior after factory reset. **Fix**: Pinned to `--version 18.2.3`.

8. **Playbook continues after database failure**: Task 28 had `failed_when: false` with no subsequent failure check, so Authentik deployed even when the database didn't exist (pods crash-loop). **Fix**: Added task 29.1 with `ansible.builtin.fail` when `postgres_setup_result.rc != 0`.

9. **Sub-playbook exit code 4**: Task 28 called `u09-authentik-create-postgres.yml` via `ansible.builtin.command` with `chdir: /mnt/urbalurbadisk/ansible`. This made the child process find `ansible/ansible.cfg` which sets `collections_path` to a directory where collections aren't installed. The global `/etc/ansible/ansible.cfg` uses default paths where they are. **Fix**: Removed `args: chdir:` from tasks 28 and 44 (all paths are absolute).

10. **Missing `-L` flag on curl login API calls (Phase 4, Round 1)**: Test B was INCONCLUSIVE because curl wasn't following 302 redirects from Authentik's flow executor. Each stage submission (identification, password) returns a 302 redirect. Without `-L`, curl got empty bodies. **Fix**: Added `-L` to all curl calls in the login flow. Also fixed success check from `"redirect"` to `"xak-flow-redirect"`.

11. **Cookie domain mismatch in Test D (Phase 4, Round 3)**: API login to `authentik-server.authentik.svc.cluster.local` sets the session cookie on that internal domain. The OAuth authorize endpoint is on `authentik.localhost` — different domain, so curl doesn't send the cookie. Authentik sees an unauthenticated request and returns the login page (HTTP 200 but HTML, not whoami content). **Fix**: Changed Test D to login through `authentik.localhost` via Traefik using `--resolve` flags so the session cookie lands on the correct domain.

12. **Standard whoami Ingress bypasses forward auth (Phase 4, Round 5)**: The `025-setup-whoami-testpod.yml` playbook creates a standard Kubernetes `Ingress` for `whoami.localhost` that routes directly to whoami WITHOUT forward auth middleware. This standard Ingress takes priority over (or competes with) the `whoami-protected` IngressRoute that has the `authentik-forward-auth` middleware. Traffic hits the bare Ingress and bypasses authentication entirely — a security issue. **Fix**: Added task 46.5 in `070-setup-authentik.yml` that deletes the standard `whoami` Ingress before deploying the protected IngressRoute. Uses `--ignore-not-found=true` for idempotency.

13. **Docker build context vs running image mismatch (Phase 4, Round 5)**: The `uis` wrapper script defaults to `IMAGE="${UIS_IMAGE:-ghcr.io/terchris/uis-provision-host:latest}"` (registry image). After rebuilding locally with `docker build ... -t uis-provision-host:local`, the container was still running the registry image. New files appeared missing from the container. **Fix**: Start container with `UIS_IMAGE=uis-provision-host:local ./uis restart` to use the locally built image.

---

## Commits

| Commit | Description |
|--------|-------------|
| `7c877a4` | Complete PLAN-007: Authentik automatic secrets and deployment fixes (Phases 0–3) |
| `a413c7e` | Add end-to-end authentication test playbook and fix Ingress conflict (Phase 4) |

---

## Future Ideas (Out of Scope)

The tester suggested a feature idea during testing:

- **Authentik CLI** - `./uis authentik users list` etc. (added to [INVESTIGATE-authentik-automation.md](./INVESTIGATE-authentik-auto-deployment.md))
