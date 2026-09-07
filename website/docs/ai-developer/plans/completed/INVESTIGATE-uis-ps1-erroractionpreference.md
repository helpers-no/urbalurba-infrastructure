# INVESTIGATE: uis.ps1 Fails on Windows Due to $ErrorActionPreference = "Stop"

**Status:** Completed — Ready for PLAN
**Created:** 2026-03-04
**Last Updated:** 2026-03-04
**GitHub Issue:** [#62](https://github.com/terchris/urbalurba-infrastructure/issues/62)
**Related to:** None
**Depends on:** None

---

## Problem Statement

`uis.ps1` fails on first run on a fresh Windows machine. The script sets `$ErrorActionPreference = "Stop"` which causes PowerShell to treat any stderr output from Docker commands as a terminating error. Docker writes to stderr for expected conditions (image not found, container doesn't exist), killing the script before fallback logic can execute.

This is Windows PowerShell-specific — there is no `uis.sh` bash host wrapper (only `uis-cli.sh` which runs inside the container).

---

## Finding 1: Two different versions of uis.ps1

There are **two completely different implementations** of the script:

| File | Lines | Description |
|------|-------|-------------|
| `uis.ps1` (repo root) | 225 | Older version. Uses `$args` for argument parsing. Has `test`, `build`, `provision`, `exec` commands. Issue #62 was filed against this version. |
| `website/static/uis.ps1` | 280 | Newer version. Uses `param()` for proper argument parsing. Has `update`, `status` commands. Better structured. Downloaded by `install.ps1`. |

The `website/build/uis.ps1` is identical to `website/static/uis.ps1` (Docusaurus build output).

**Key problem:** Users who run `install.ps1` get `website/static/uis.ps1`. Users who clone the repo get the root `uis.ps1`. These are **not the same script**. Both have `$ErrorActionPreference = "Stop"`.

### Which version is canonical?

The `install.ps1` downloads from `https://uis.sovereignsky.no/uis.ps1`, which serves `website/static/uis.ps1`. This is the version end users get. The root `uis.ps1` appears to be the older development version.

**Decision needed:** Should the root `uis.ps1` be deleted or replaced with the website/static version?

---

## Finding 2: Root uis.ps1 — 26 Docker invocations, most unprotected

The issue reports 2 broken lines, but the actual exposure is much larger:

### Docker commands WITH stderr redirection (9 calls)

| Line | Command | LASTEXITCODE check | Risk |
|------|---------|-------------------|------|
| **22** | `docker image inspect $Image 2>&1` | Yes | **BREAKS on first run** — image not pulled |
| **84** | `docker rm -f $ContainerName 2>$null` | No | **BREAKS on first run** — no container |
| 72 | `docker exec ... 2>$null` (welcome) | No | Low |
| 76 | `docker ps ... 2>$null` | Piped | Low |
| 106 | `docker exec ... 2>$null` (kubeconfig) | No | Low |
| 111 | `docker exec ... init 2>$null` | No | Low |
| 117 | `docker ps ... 2>$null` (stop check) | Piped | Low |
| 145 | `docker ps ... 2>$null` (status check) | Piped | Low |
| 183 | `docker exec ... rm -rf 2>$null` (test) | No | Low |

### Docker commands WITHOUT any stderr handling (17 calls)

These will also terminate the script if Docker writes anything to stderr:

| Line | Command | LASTEXITCODE check |
|------|---------|-------------------|
| 27 | `docker pull $Image` | Yes |
| 98 | `docker run -d ...` | Yes |
| 120 | `docker stop $ContainerName` | No |
| 148 | `docker ps --filter ...` | No |
| 155 | `docker exec -it ... bash` (shell) | No |
| 160 | `docker exec -it ... provision` | No |
| 168 | `docker exec ... @remaining` | No |
| 172 | `docker logs ...` | No |
| 176 | `docker build ...` | No |
| 186-203 | 8x `docker exec` (test commands) | No |
| 209 | `docker exec ... help` | No |
| 223 | `docker exec ... @args` (default) | No |

---

## Finding 3: Website/static uis.ps1 — same root cause, better patterns

The newer version also has `$ErrorActionPreference = "Stop"` (line 16), but uses better patterns in some places:

| Line | Command | Pattern | Still vulnerable? |
|------|---------|---------|-------------------|
| 57 | `docker ps ... 2>$null` | Piped to Where-Object | Low risk |
| 64 | `docker image inspect ... 2>$null` | **try/catch** | **Fixed** |
| 77 | `docker pull $Image` | LASTEXITCODE check | **Still vulnerable** — stderr terminates |
| 105 | `docker rm -f ... 2>$null` | Piped to Out-Null | **Still vulnerable** |
| 136 | `& docker @dockerArgs` | No stderr handling | **Still vulnerable** |
| 144 | `docker exec ... 2>$null` | **try/catch** | **Fixed** |
| 154 | `docker stop ...` | Piped to Out-Null | **Still vulnerable** |
| 155 | `docker rm ... 2>$null` | Piped to Out-Null | **Still vulnerable** |
| 166 | `docker ps --filter ...` | No stderr handling | **Still vulnerable** |
| 177 | `docker pull $Image` | LASTEXITCODE check | **Still vulnerable** |
| 201 | `docker exec -it ...` | No stderr handling | **Still vulnerable** |
| 262 | `docker exec -it ... bash` | No stderr handling | **Still vulnerable** |
| 266 | `docker logs ...` | No stderr handling | **Still vulnerable** |

The newer version uses `try/catch` for `Test-ImageExists` (line 63-68) which properly handles the first-run image inspect issue. But `docker rm -f` (line 105), `docker pull` (line 77), and many other calls remain unprotected.

---

## Finding 4: install.ps1 also affected

`website/static/install.ps1` has `$ErrorActionPreference = "Stop"` (line 14).

| Line | Command | Risk |
|------|---------|------|
| 40 | `docker info 2>&1` | Low — wrapped in try/catch |
| 78 | `docker pull $Image` | **Vulnerable** — stderr from `docker pull` (progress output) could terminate script |

The `docker pull` on line 78 writes progress to stderr. With `$ErrorActionPreference = "Stop"`, this **may** terminate the script on some PowerShell versions. It's less reliably broken than the inspect case, but still a risk.

---

## Finding 5: No uis.sh host wrapper exists

There is no bash equivalent of the host wrapper. Only:
- `uis.ps1` / `uis.cmd` — Windows host wrapper
- `uis-cli.sh` — runs **inside** the container

Linux/macOS users must use Docker commands directly or enter the container manually. This is a separate gap but out of scope for this issue.

---

## Finding 6: No CI/CD testing of PowerShell scripts

The GitHub Actions workflow `test-uis.yml` only tests bash scripts inside the container. None of the PowerShell scripts (`uis.ps1`, `install.ps1`) are tested in CI/CD. This explains how the bug reached users.

---

## Finding 7: uis.cmd wrapper

`website/static/uis.cmd` is a thin wrapper that calls `uis.ps1`:

```cmd
powershell -ExecutionPolicy Bypass -File "%~dp0uis.ps1" %*
```

This allows Windows Command Prompt users to run `uis start` instead of `.\uis.ps1 start`. No issues here — the bug is in the PowerShell script it calls.

---

## Options

### Option A: Remove `$ErrorActionPreference = "Stop"` entirely

**Pros:**
- Eliminates root cause in one line
- Docker CLI wrapper scripts don't benefit from automatic error termination
- Non-Docker PowerShell commands (`New-Item`, `Set-Content`) are unlikely to fail silently

**Cons:**
- Loses automatic error catching for rare PowerShell-native failures

### Option B: Use try/catch around all Docker calls

The website/static version already does this for `Test-ImageExists`. Extend to all Docker calls.

**Pros:**
- PowerShell-idiomatic
- Keeps global error preference for non-Docker code

**Cons:**
- Verbose — every Docker call needs wrapping
- Easy to miss when adding new calls

### Option C: Remove `$ErrorActionPreference = "Stop"` + consolidate to one script

Remove the root `uis.ps1`, make `website/static/uis.ps1` the single canonical version, and fix the `$ErrorActionPreference` issue there.

**Pros:**
- Fixes the bug AND eliminates the "two versions" problem
- Single source of truth
- The website/static version is already better structured

**Cons:**
- Larger scope of change
- Need to verify the root uis.ps1 isn't referenced anywhere else

---

## Recommendation

**Option C** — Fix the bug in `website/static/uis.ps1` (the canonical version users download) and decide what to do with the root `uis.ps1`.

Specifically:
1. Remove `$ErrorActionPreference = "Stop"` from `website/static/uis.ps1`
2. Verify all critical Docker commands check `$LASTEXITCODE`
3. Apply the same fix to `website/static/install.ps1`
4. Decide whether root `uis.ps1` should be deleted, symlinked, or replaced

---

## Questions for User

1. **Which uis.ps1 is canonical?** The root version (225 lines, used in development) or the website/static version (280 lines, downloaded by install.ps1)?
2. **Should the root uis.ps1 be removed?** If website/static is canonical, the root version is confusing and could mislead developers.
3. **Should we add PowerShell CI/CD testing?** A simple `pwsh -File uis.ps1 help` in GitHub Actions would catch syntax errors.

---

## Next Step

- [ ] Get user input on which version is canonical and whether to consolidate
- [ ] Create PLAN with the fix
