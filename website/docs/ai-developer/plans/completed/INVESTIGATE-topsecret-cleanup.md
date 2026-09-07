# INVESTIGATE: Remove All `topsecret/` References from Codebase

**Related**: [PLAN-004-secrets-cleanup](./PLAN-004-secrets-cleanup.md), [STATUS-service-migration](STATUS-service-migration.md), [INVESTIGATE-secrets-consolidation](./INVESTIGATE-secrets-consolidation.md)
**Created**: 2026-02-22
**Status:** Completed

## Background

The secrets system has been fully migrated from `topsecret/` to `.uis.secrets/`. All 23 verified services deploy and undeploy cleanly using the new paths (talk9.md, talk10.md). The old `topsecret/` directory and backwards compatibility code should be removed.

PLAN-004 (completed plan) covers the core UIS system cleanup — removing backwards compatibility code from `paths.sh`, `secrets-management.sh`, the `uis` wrapper, Dockerfile, and tests. This investigation extends the scope to cover **every** remaining `topsecret/` reference across the entire codebase.

## Scan Results

**48 files** reference `topsecret/` outside the `topsecret/` directory itself.

| Category | Count |
|----------|:-----:|
| Active scripts | 11 |
| Documentation | 27 |
| CI/CD | 1 |
| Manifests | 1 |
| Other (root scripts, .dockerignore, cloud-init) | 8 |

---

## Category 1: Core UIS System (covered by PLAN-004)

These files are already fully documented in PLAN-004. Included here for completeness.

| File | Reference | Change |
|------|-----------|--------|
| `provision-host/uis/lib/paths.sh` | `OLD_SECRETS_BASE`, `warn_deprecated_path()`, `is_using_legacy_paths()` | Remove backwards compat section (lines 166-416), simplify 7 functions |
| `provision-host/uis/lib/secrets-management.sh` | `has_topsecret_config()`, legacy fallback | Remove function, remove fallback |
| `uis` (root wrapper) | `check_topsecret()`, topsecret volume mount | Remove function, remove mount |
| `provision-host/provision-host-vm-create.sh` | `rsync topsecret/` | Remove rsync block |
| `ansible/playbooks/04-merge-kubeconf.yml` | `legacy_kubernetes_files_path` | Remove legacy path, simplify |
| `provision-host/uis/lib/first-run.sh` | Comment only | Update comment |
| `Dockerfile.uis-provision-host` | `COPY topsecret/`, `mkdir topsecret/` | Remove lines |
| `provision-host/uis/tests/unit/test-backwards-compat-paths.sh` | Entire file | Delete |
| `provision-host/uis/tests/unit/test-paths.sh` | Legacy test sections | Remove sections |
| `provision-host/uis/tests/unit/test-phase6-secrets.sh` | `has_topsecret_config` | Remove from check |
| `.gitignore` | ~7 `topsecret/` entries | Remove entries |
| `secrets/create-secrets.sh` | Entire file | Delete |
| `topsecret/` directory | 24 tracked files | Delete entire directory |

---

## Category 2: Root Scripts

These scripts run on the host (outside the container) and have fallback logic supporting both `.uis.secrets/` and `topsecret/`.

### `install-rancher.sh`

- **Line 93**: `if [ ! -d ".uis.secrets" ] && [ ! -d "topsecret" ]; then` — fallback in `check_required_files()`
- **Line 97**: `if [ ! -d ".uis.secrets/ssh" ] && [ ! -d "secrets" ]; then` — SSH key fallback
- **Lines 134-139**: Legacy `create-kubernetes-secrets.sh` path:
  ```bash
  elif [ -d "topsecret" ]; then
      run_script_from_directory "topsecret" "create-kubernetes-secrets.sh"
  ```
- **Change**: Remove all `topsecret` and `secrets` fallbacks. Keep only `.uis.secrets` paths.

### `copy2provisionhost.sh`

- **Lines 53-54**: Backup path check: `elif docker exec provision-host test -f /mnt/urbalurbadisk/topsecret/kubernetes/kubernetes-secrets.yml`
- **Lines 82-88**: Copy topsecret to container: `docker cp topsecret/. provision-host:/mnt/urbalurbadisk/topsecret`
- **Change**: Remove topsecret backup check and copy block. Keep only `.uis.secrets` handling.

### `provision-host-rancher/provision-host-container-create.sh`

- **Line 173**: Creates and copies topsecret directory to container
- **Change**: Remove topsecret copy.

---

## Category 3: Networking Scripts

These run inside the provision-host container and check for `topsecret/` as a fallback.

### `networking/tailscale/802-tailscale-tunnel-deploy.sh`

- **Lines 92-98**: Environment check with fallback:
  ```bash
  if [ -d "/mnt/urbalurbadisk/.uis.secrets" ]; then
      SECRETS_DIR_OK=true
  elif [ -d "/mnt/urbalurbadisk/topsecret" ]; then
      SECRETS_DIR_OK=true
  fi
  ```
- **Line 102**: Error message mentions both paths
- **Change**: Remove `elif` fallback, update error message.

### `networking/cloudflare/820-cloudflare-tunnel-setup.sh`

- **Lines 94-100**: Fallback path:
  ```bash
  if [[ -f "/mnt/urbalurbadisk/provision-host/uis/lib/paths.sh" ]]; then
      source "/mnt/urbalurbadisk/provision-host/uis/lib/paths.sh"
      K8S_SECRETS_PATH=$(get_kubernetes_secrets_path)
  else
      K8S_SECRETS_PATH="/mnt/urbalurbadisk/topsecret/kubernetes"
  fi
  ```
- **Line 205**: Reference to `topsecret/copy-secrets2host.sh`
- **Change**: Remove else fallback. Consider sourcing `paths.sh` or using `.uis.secrets/` directly.

### `networking/cloudflare/821-cloudflare-tunnel-deploy.sh`

- **Lines 35, 75-85**: Multiple fallback checks to topsecret directory
- **Change**: Remove fallback logic.

### `networking/cloudflare/822-cloudflare-tunnel-delete.sh`

- **Line 28**: `K8S_SECRETS_PATH="/mnt/urbalurbadisk/topsecret/kubernetes"` (hardcoded, no fallback)
- **Change**: Replace with `.uis.secrets/generated/kubernetes`.

---

## Category 4: Host Scripts

These scripts install the system on different platforms (Azure, Raspberry Pi, Multipass). They reference `topsecret/` for secrets.

### `hosts/install-rancher-kubernetes.sh`

- **Lines 110-111**: Checks for `../topsecret/kubernetes/kubernetes-secrets.yml`
- **Line 119**: `SECRETS_FILE="../topsecret/kubernetes/kubernetes-secrets.yml"`
- **Line 134**: `run_script_from_directory "../topsecret" "update-kubernetes-secrets-rancher.sh"`
- **Change**: Replace with `.uis.secrets/` paths.

### `hosts/azure-aks/02-azure-aks-setup.sh`

- **Line 132**: `SECRETS_FILE="/mnt/urbalurbadisk/topsecret/kubernetes/kubernetes-secrets.yml"`
- **Change**: Replace with `.uis.secrets/` path.

### `hosts/install-azure-microk8s-v2.sh`

- **Line 216**: References topsecret directory
- **Change**: Replace with `.uis.secrets/` path.

### `hosts/install-azure-aks.sh`

- **Line 12**: Comment: "topsecret repository is available at ../topsecret"
- **Change**: Update comment.

### `hosts/install-multipass-microk8s.sh`

- **Lines 83, 89**: Calls topsecret scripts
- **Change**: Replace with `.uis.secrets/` equivalents.

### `hosts/raspberry-microk8s/install-raspberry.sh`

- **Lines 97-98, 102**: Commented-out references to topsecret scripts
- **Change**: Remove commented-out lines.

---

## Category 5: Cloud Init

### `cloud-init/create-cloud-init.sh`

- **Line 27**: `KUBERNETES_SECRETS_FILE="../topsecret/kubernetes/kubernetes-secrets.yml"`
- **Change**: Replace with `.uis.secrets/` path.

---

## Category 6: CI/CD

### `.github/workflows/build-uis-container.yml`

- **Line 23**: Path trigger `'topsecret/secrets-templates/**'`
- **Change**: Remove this path trigger (templates now live in `provision-host/uis/templates/`).

---

## Category 7: Docker & Manifests

### `.dockerignore`

- **Lines 24-27**: Excludes `topsecret/` subdirectories
- **Change**: Remove all 4 entries (directory won't exist after cleanup).

### `manifests/220-litellm-config.yaml`

- **Line 109**: Comment: "The model configuration is now managed in topsecret/kubernetes/kubernetes-secrets.yml"
- **Change**: Update comment to reference `.uis.secrets/`.

---

## Category 8: Documentation (27 files)

All are text-only changes — update references from `topsecret/` to `.uis.secrets/`.

| File | Lines | Type of Reference |
|------|:-----:|-------------------|
| `website/docs/index.md` | 93, 135 | Directory structure diagram |
| `website/docs/getting-started/architecture.md` | 88 | Directory structure diagram |
| `website/docs/reference/secrets-management.md` | 26, 41 | `cd topsecret/`, directory structure |
| `website/docs/reference/manifests.md` | 82 | Secrets directory reference |
| `website/docs/services/authentication/auth10.md` | 236, 493, 513-514, 523, 666, 686, 702 | Edit instructions for kubernetes-secrets.yml |
| `website/docs/services/authentication/index.md` | 26 | Configuration reference |
| `website/docs/services/authentication/developer-guide.md` | 9, 12, 109, 129 | Edit instructions |
| `website/docs/services/datascience/index.md` | 320 | Secrets reference |
| `website/docs/services/datascience/jupyterhub.md` | 91 | `cd /mnt/urbalurbadisk/topsecret` |
| `website/docs/services/ai/litellm.md` | 48, 63, 160, 168 | ConfigMap reference |
| `website/docs/services/ai/openwebui-model-access.md` | 16, 58, 70 | Model config reference |
| `website/docs/services/ai/index.md` | 303 | ConfigMap reference |
| `website/docs/services/ai/environment-management.md` | 15, 24, 75, 79, 88, 137, 141, 282 | Multiple ConfigMap references |
| `website/docs/provision-host/tools.md` | 184 | Directory structure |
| `website/docs/rules/development-workflow.md` | 173, 187, 297 | Directory structure, workflow |
| `website/docs/networking/tailscale-setup.md` | 163, 184, 318, 341, 347 | Secrets editing instructions |
| `provision-host/uis/templates/how-secrets-works.md` | 168, 170, 278, 280 | Migration documentation |

---

## Category 9: Completed Plan Files (DO NOT MODIFY)

These files are historical records documenting decisions and investigations. They should NOT be modified.

- `plans/completed/PLAN-001-secrets-folder-structure.md`
- `plans/completed/PLAN-002-uis-cli-commands.md`
- `plans/completed/PLAN-003-script-migration.md`
- `plans/completed/PLAN-003-minimal-container-delivery.md`
- `plans/completed/PLAN-004-secrets-cleanup.md`
- `plans/completed/PLAN-004B-menu-secrets.md`
- `plans/completed/PLAN-004-uis-orchestration-system.md`
- `plans/completed/PLAN-007-authentik-auto-secrets.md`
- `plans/backlog/INVESTIGATE-secrets-consolidation.md`
- `plans/backlog/INVESTIGATE-uis-distribution.md`
- `plans/backlog/INVESTIGATE-argocd-migration.md`
- `plans/backlog/STATUS-service-migration.md`
- `PLAN-docs-restructure.md`

---

## Proposed Implementation Order

| Phase | Scope | Files | Risk |
|-------|-------|:-----:|------|
| 1 | Core UIS cleanup (PLAN-004) | ~13 | Medium — removes active fallback code |
| 2 | Root + networking + host scripts | ~14 | Medium — scripts must still work after change |
| 3 | CI/CD, .dockerignore, manifests | 3 | Low — config and comments only |
| 4 | Documentation | ~17 | None — text only |
| **Total** | | **~47** | |

## Verification

After all changes:

```bash
# No topsecret references in code
grep -rn "topsecret" --include="*.sh" --include="*.yml" --include="*.yaml" \
  provision-host/ ansible/ uis networking/ hosts/ cloud-init/ \
  install-rancher.sh copy2provisionhost.sh Dockerfile.uis-provision-host \
  .github/ .dockerignore manifests/
# Should return nothing

# No topsecret references in docs (excluding historical plan files)
grep -rn "topsecret" website/docs/ provision-host/uis/templates/how-secrets-works.md \
  | grep -v "plans/completed/" | grep -v "plans/backlog/"
# Should return nothing

# Container builds
./uis build

# Tests pass
# (run inside container)
cd provision-host/uis/tests && bash run-all-tests.sh

# Deploy/undeploy a service
./uis deploy whoami && ./uis undeploy whoami
```

## Open Questions

1. Are the host scripts (`hosts/azure-aks/`, `hosts/install-multipass-microk8s.sh`, etc.) actively used, or are they legacy scripts superseded by the UIS system?
2. Should this be one PR or split into multiple (e.g., core code vs. documentation)?
3. Should a git tag be created before cleanup for easy rollback?
