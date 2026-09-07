# INVESTIGATE: Undeploy --purge flag

**Status:** Completed (2026-05-16) — `--purge` flag implemented in `provision-host/uis/manage/uis-cli.sh` (lines 393-453). Includes confirmation prompt + `--yes` for scripted use.
**Source**: Tester feedback during PLAN-002 (Backstage deployment testing, 2026-03-12)

## Problem

When undeploying stateful services like PostgreSQL, the PVC (persistent data) is preserved by default. During testing and clean-slate scenarios, users must manually run `kubectl delete pvc` to fully remove data. This is error-prone and adds friction.

## Proposed Solution

Add a `--purge` flag to `./uis undeploy <service>` that also deletes associated PVCs, giving a completely clean removal.

Requirements:
- Default behavior unchanged: `./uis undeploy postgresql` preserves PVCs (safe)
- `./uis undeploy postgresql --purge` deletes PVCs after Helm uninstall
- Should work for any stateful service (PostgreSQL, MySQL, MongoDB, Redis, etc.)
- Should display a warning before deleting data
- Consider adding a `--yes` flag to skip confirmation for scripted use

## Affected Services

Any service with persistent storage:
- PostgreSQL (`data-postgresql-0`)
- MySQL
- MongoDB
- Redis
- Elasticsearch
- Any future stateful services

## Notes

- The remove playbooks already handle Helm uninstall and namespace cleanup
- PVC deletion would need to happen after Helm uninstall but before namespace deletion
- Could be implemented in the CLI wrapper (`uis-cli.sh`) or in the Ansible remove playbooks
