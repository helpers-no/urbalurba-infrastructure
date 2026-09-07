# PLAN-004: Secrets Migration Cleanup & Finalization

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: Remove backwards compatibility code, delete deprecated files (`topsecret/`, `secrets/`), and update tests. The new `.uis.secrets/` and `.uis.extend/` structure is fully operational — this plan removes the old scaffolding.

**Last Updated**: 2026-02-22
**Completed**: 2026-02-22 — All acceptance criteria verified. Work was done incrementally across PLAN-005 (kubeconfig migration), PR #35 (old path fixes), and earlier sessions.

**Branch**: `feature/secrets-cleanup`

**Prerequisites**: All old path references in playbooks fixed and verified (PR #35, merged)

**Related**: [INVESTIGATE-secrets-consolidation](./INVESTIGATE-secrets-consolidation.md), [INVESTIGATE-passwords](./INVESTIGATE-passwords.md)

**Deferred items** (active hard dependencies, separate plan needed):
- `cloud-init/` folder — still referenced by `provision-host-vm-create.sh`, host scripts
- `hosts/` folder configs — azure scripts actively used, scripts copied to VMs
- Documentation updates (17+ user-facing docs) — large scope, separate PR

---

## Context: Contributor vs User

**We are contributors** - we clean up the codebase and finalize the migration.

This plan:
1. Removes backwards compatibility code from scripts
2. Removes deprecated files and folders from the repo
3. Updates tests to match the simplified code
4. Does NOT affect user folders (`.uis.extend/`, `.uis.secrets/` - those are created at runtime)

---

## Phase 1: Remove Backwards Compatibility Code

### 1.1 `provision-host/uis/lib/paths.sh`

Remove the entire backwards-compatibility section (lines 166-416):

- Remove `OLD_SECRETS_BASE`, `OLD_SSH_BASE`, `_DEPRECATION_WARNING_SHOWN` constants
- Remove `warn_deprecated_path()` function
- Simplify 7 functions to one-liners returning only new paths:

| Old function | New implementation |
|---|---|
| `get_secrets_base_path()` | Remove entirely (use `get_secrets_dir()` instead) |
| `get_ssh_key_path()` | `echo "$(get_secrets_dir)/ssh"` |
| `get_kubernetes_secrets_path()` | `echo "$(get_secrets_dir)/generated/kubernetes"` |
| `get_cloud_init_output_path()` | `echo "$(get_secrets_dir)/generated/ubuntu-cloud-init"` |
| `get_kubeconfig_path()` | `echo "$(get_secrets_dir)/generated/kubeconfig"` |
| `get_tailscale_key_path()` | `echo "$(get_secrets_dir)/service-keys/tailscale.env"` |
| `get_cloudflare_token_path()` | `echo "$(get_secrets_dir)/service-keys/cloudflare.env"` |

- Remove `is_using_legacy_paths()`
- Keep: `is_using_new_paths()`, `ensure_path_exists()`, `get_cloud_credentials_path()`

### Validation 1.1

```bash
# Verify no OLD_ or deprecation references remain
grep -n "OLD_SECRETS\|OLD_SSH\|warn_deprecated\|is_using_legacy" provision-host/uis/lib/paths.sh
# Should return nothing
```

### 1.2 `provision-host/uis/lib/secrets-management.sh`

- Line 5: Update comment (remove `topsecret/` reference)
- Lines 48-51: Remove legacy fallback to `topsecret/secrets-templates` in `get_secrets_templates_dir()`
- Lines 70-80: Remove `has_topsecret_config()` function entirely
- Remove any legacy path from `apply_secrets()` file_locations array (if present)

### Validation 1.2

```bash
grep -n "topsecret\|has_topsecret" provision-host/uis/lib/secrets-management.sh
# Should return nothing
```

### 1.3 `uis` (root wrapper)

- Lines 32-39: Remove `check_topsecret()` function
- Lines 130-133: Remove topsecret volume mount (`if check_topsecret; then ... fi`)
- Lines 136-138: Remove `secrets/` volume mount (`if [ -d "$SCRIPT_DIR/secrets" ]; then ... fi`)
- Lines 159-174: Remove legacy kubeconfig symlink setup. Keep only the new `.uis.secrets/generated/kubeconfig` symlink:
  ```bash
  docker exec "$CONTAINER_NAME" bash -c '
      if [ -d /mnt/urbalurbadisk/.uis.secrets ]; then
          mkdir -p /mnt/urbalurbadisk/.uis.secrets/generated/kubeconfig
          ln -sf /home/ansible/.kube/config /mnt/urbalurbadisk/.uis.secrets/generated/kubeconfig/kubeconf-all
      fi
  ' 2>/dev/null || true
  ```

### Validation 1.3

```bash
grep -n "topsecret\|check_topsecret\|/secrets:" uis
# Should return nothing
```

### 1.4 `provision-host/provision-host-vm-create.sh`

- Lines 152-154: Remove topsecret rsync block:
  ```bash
  # REMOVE:
  if [ -d "../topsecret" ]; then
      rsync -av --delete ../topsecret/ $VM_NAME:/mnt/urbalurbadisk/topsecret/
  fi
  ```

### 1.5 `ansible/playbooks/04-merge-kubeconf.yml`

- Remove `legacy_kubernetes_files_path` variable (line 36)
- Simplify `kubernetes_files_path` to single value: `"/mnt/urbalurbadisk/.uis.secrets/generated/kubeconfig/"` (line 34)
- Remove dynamic path selection (line 38)
- Remove entire `pre_tasks` block (lines 57-79): stat check, set_fact, deprecation warning

### Validation 1.5

```bash
grep -n "legacy\|deprecat" ansible/playbooks/04-merge-kubeconf.yml
# Should return nothing
```

### 1.6 `provision-host/uis/lib/first-run.sh`

- Line 241: Update comment to remove `topsecret` reference (describe workflow without mentioning old paths)

### Phase 1 Validation

```bash
# No topsecret references in modified code files
grep -rn "topsecret" --include="*.sh" provision-host/uis/lib/ uis
grep -rn "topsecret" --include="*.yml" ansible/playbooks/04-merge-kubeconf.yml
# Should return nothing

# No OLD_SECRETS/OLD_SSH references
grep -rn "OLD_SECRETS\|OLD_SSH\|warn_deprecated\|check_topsecret\|has_topsecret" \
  --include="*.sh" provision-host/ uis
# Should return nothing
```

---

## Phase 2: Update Dockerfile

### `Dockerfile.uis-provision-host`

- Line 64: Remove `COPY topsecret/secrets-templates/ /mnt/urbalurbadisk/topsecret/secrets-templates/`
  (templates already exist in `provision-host/uis/templates/secrets-templates/`)
- Lines 85-87: Remove `mkdir -p /mnt/urbalurbadisk/topsecret/...` block

### Validation

```bash
grep -n "topsecret" Dockerfile.uis-provision-host
# Should return nothing
```

---

## Phase 3: Update Test Files

### 3.1 Delete `provision-host/uis/tests/unit/test-backwards-compat-paths.sh`

Entire 358-line test suite for backwards compatibility — no longer needed.

```bash
git rm provision-host/uis/tests/unit/test-backwards-compat-paths.sh
```

### 3.2 Update `provision-host/uis/tests/unit/test-paths.sh`

Remove backwards-compat tests (lines 151-273):
- "Legacy Path Constants Tests" section
- "Backwards-Compatible Function Definition Tests" section (tests for `warn_deprecated_path`, `is_using_legacy_paths`, etc.)
- "Backwards-Compatible Function Output Tests" section

### 3.3 Update `provision-host/uis/tests/unit/test-phase6-secrets.sh`

- Line 43: Remove `has_topsecret_config` from the function existence check loop

### Validation

```bash
# Run remaining tests
cd provision-host/uis/tests && bash run-all-tests.sh
# All tests should pass
```

---

## Phase 4: Remove Deprecated Files from Repo

### 4.1 Delete `secrets/` folder

```bash
git rm secrets/create-secrets.sh
```

Note: `id_rsa_ansible` and `id_rsa_ansible.pub` are NOT tracked (gitignored) — only `create-secrets.sh` is.

### 4.2 Delete `topsecret/` folder

```bash
git rm -r topsecret/
```

Removes 24 tracked files: DEPRECATED.md, 5 scripts, secrets-templates/ (13 files), kubernetes/ (4 argocd files).

### 4.3 Clean up `.gitignore`

Remove ~7 dead entries referencing `topsecret/` paths (lines 8-11, 20-21, 45).

### Validation

```bash
# Verify files are gone
ls secrets/ topsecret/ 2>&1
# Should show "No such file or directory"

# Verify gitignore is clean
grep "topsecret" .gitignore
# Should return nothing
```

---

## Phase 5: Build and Verify

### 5.1 Build container

```bash
docker build -f Dockerfile.uis-provision-host -t uis-provision-host:local .
```

### 5.2 Run unit tests

```bash
# Inside container or locally
cd provision-host/uis/tests && bash run-all-tests.sh
```

### 5.3 Verification commands

```bash
# No topsecret references in code (excluding docs, plans, cloud-init/, hosts/)
grep -rn "topsecret" --include="*.sh" --include="*.yml" --include="*.yaml" \
  provision-host/uis/ ansible/ uis Dockerfile.uis-provision-host

# No OLD_SECRETS/OLD_SSH references
grep -rn "OLD_SECRETS\|OLD_SSH\|warn_deprecated\|check_topsecret\|has_topsecret" \
  --include="*.sh" provision-host/ uis

# Container builds successfully
# Unit tests pass
```

---

## Files Summary

| Action | File |
|--------|------|
| Modify | `provision-host/uis/lib/paths.sh` |
| Modify | `provision-host/uis/lib/secrets-management.sh` |
| Modify | `uis` (root wrapper) |
| Modify | `provision-host/provision-host-vm-create.sh` |
| Modify | `ansible/playbooks/04-merge-kubeconf.yml` |
| Modify | `provision-host/uis/lib/first-run.sh` |
| Modify | `Dockerfile.uis-provision-host` |
| Modify | `provision-host/uis/tests/unit/test-paths.sh` |
| Modify | `provision-host/uis/tests/unit/test-phase6-secrets.sh` |
| Modify | `.gitignore` |
| Delete | `provision-host/uis/tests/unit/test-backwards-compat-paths.sh` |
| Delete | `secrets/create-secrets.sh` |
| Delete | `topsecret/` (24 tracked files) |

---

## Acceptance Criteria

- [ ] No references to `topsecret/` in code files (scripts, playbooks, Dockerfile)
- [ ] No references to `OLD_SECRETS`, `OLD_SSH`, or `warn_deprecated` in code
- [ ] `topsecret/` folder deleted from repo
- [ ] `secrets/` folder deleted from repo
- [ ] `uis` wrapper only mounts `.uis.extend/` and `.uis.secrets/`
- [ ] `.gitignore` cleaned up
- [ ] Backwards compat test file deleted
- [ ] Remaining tests updated and passing
- [ ] Container builds successfully

---

## Risk Mitigation

1. **Git tag before cleanup** — Create tag for easy rollback
2. **Feature branch** — All work on `feature/secrets-cleanup`
3. **Deferred items are safe** — `cloud-init/`, `hosts/`, and docs are NOT touched in this plan
4. **No user-facing changes** — Runtime `.uis.extend/` and `.uis.secrets/` folders are unaffected
